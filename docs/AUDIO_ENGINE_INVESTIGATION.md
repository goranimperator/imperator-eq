# Audio Engine Investigation: AUHAL Render Stall

## Problem

AUHAL slutar anropa render callbacken efter 5-30 minuter. Ingen krasch, inga errors, processen lever. Ljudet bara dör.

## Symptom

1. Appen startar korrekt — alla status = 0, render callback anropas ~93 ggr/sek
2. Efter 5-30 minuter slutar render callbacken anropas helt
3. Aggregate device kan fortfarande finnas kvar (inget CoreAudio-error)
4. BlackHole är fortfarande default output, inte mutad, volym OK
5. Process lever — ingen krasch, ingen SIGTERM
6. Ingen render error rapporteras (consecutiveErrors = 0)

## Miljö

- macOS (Apple Silicon M1)
- BlackHole 2ch som virtual loopback
- Aggregate device: BlackHole (input) + real output (speakers/headphones)
- AUHAL (kAudioUnitSubType_HALOutput) med render callbacks
- AUNBandEQ för 10-band parametric EQ
- Extern skärm via DisplayPort (PHL 273B9) ofta ansluten

## Observationer

### Session 1 (utan drift compensation, utan watchdog)
- Start: 14:02:36
- Död: ~14:07 (ca 5 min)
- Aggregate device försvunnen vid manuell check
- Process fortfarande vid liv

### Session 2 (med drift compensation, utan watchdog)  
- Start: 14:12:36
- Död: ~14:40 (ca 28 min) — användaren märkte vid ~14:46
- Aggregate device försvunnen vid extern check (men privat → kanske bara osynlig utifrån)
- Recovery-loggen (vid kill) visade att aggregate FANNS som stale device
- Inga extra loggar — ingen render error rapporterad

### Session 3 (med drift comp + watchdog med Timer)
- Start: 14:48:13
- Watchdog startade men TRIGGADE ALDRIG (Timer.scheduledTimer fungerade inte med @MainActor)
- Ljud dog efter okänd tid
- Inga watchdog-loggar alls

### Session 4 (med drift comp + watchdog med DispatchSourceTimer)
- Start: 14:58:59 / 15:06:36
- Watchdog verifierad att ticka var 5:e sek (renders=469, 937, ...)
- Inväntar resultat...

## Nuvarande arkitektur

```
System audio → BlackHole 2ch (default output)
                   ↓
         Aggregate Device (private)
         ├── Sub: Real output (master clock)
         └── Sub: BlackHole (drift compensated)
                   ↓
              AUHAL (element 1 = input from aggregate)
                   ↓
              AUNBandEQ (10-band parametric)
                   ↓
              Render callback (volume/balance/boost)
                   ↓
              AUHAL (element 0 = output to aggregate → real speakers)
```

## Nuvarande skydd

| Lager | Implementerad | Funkar? |
|-------|--------------|---------|
| Drift compensation (kAudioSubDeviceDriftCompensationKey) | ✅ | Förlängde livstid från ~5 till ~28 min |
| Watchdog (render count) | ✅ | Timer fixad, tickar — ej testad vid stall ännu |
| Crash recovery (fil + signal handler) | ✅ | Funkar |
| Startup unmute | ✅ | Funkar |

## Hypoteser att undersöka

1. **Sample rate change** — extern skärm (DisplayPort) kan trigga sample rate-ändring som förstör aggregate/AUHAL
2. **Device configuration change** — CoreAudio reconfigurerar aggregate vid hot-plug events
3. **IOProc stopped** — AUHAL:s IOProc stoppas internt av CoreAudio utan error-rapportering
4. **Thread priority** — render-tråden tappar realtime priority efter tid
5. **Aggregate sub-device disconnect** — en sub-device tappar kopplingen inuti aggregatet
6. **eqMac/Background Music approach** — kanske de använder en helt annan strategi (ej aggregate, utan tap/divert)

## Frågor för research

1. Hur hanterar eqMac och Background Music AUHAL + aggregate device stabilitet?
2. Finns det kända CoreAudio-buggar med AUHAL som slutar processa utan error?
3. Bör vi använda AudioDeviceCreateIOProcID istället för AUHAL?
4. Ska vi installera en property listener på aggregate device:n för att fånga config-ändringar?
5. Finns det en AudioUnit notification/callback som triggas när AUHAL stoppar sin IOProc?
6. Är macOS 14/15 process tap API ett bättre alternativ?
