# Decisiones

Por qué está hecho así y no de otra forma.

## Avisar transiciones, no estados

Un disco al 91 % no genera un mensaje cada 5 minutos: genera **uno** cuando cruza el umbral y **otro** cuando se normaliza. Nada en el medio.

Sin esa regla son 288 mensajes por día. Silenciás el canal, y la noche que se cae la base no te enterás. El workflow guarda el estado de cada problema entre corridas (`/var/lib/metrics-alert/state.json`) y compara:

| Situación | Qué llega |
|---|---|
| Problema nuevo | 🔴 o 🟡 aviso |
| Mismo problema, sigue | nada |
| Pasa de aviso a crítico | 🔺 escalada |
| Se resuelve | ✅ con cuánto duró |
| Primera corrida | «Monitoreo iniciado» con la línea de base |

La primera corrida no avisa de lo que ya estaba mal: lo toma como línea de base. Si no, al importar el workflow te llega el inventario de problemas viejos como si acabaran de pasar.

El estado se guarda **siempre**, haya o no alertas. Si se guardara sólo al alertar, un problema resuelto nunca quedaría registrado como resuelto.

## Umbrales

| Chequeo | Aviso | Crítico |
|---|---|---|
| Disco | 70 % | 85 % |
| RAM | — | 90 % |
| CPU | — | 95 % |
| Load | — | > cores × 2,5 |
| Certificado TLS | 21 días | 7 días |
| Servicio caído | — | siempre |
| Host sin reportar | — | 15 min |

RAM y CPU avisan sólo en crítico: un pico de 75 % dura dos minutos y nadie tiene que hacer nada. El disco avisa temprano porque crece despacio y da tiempo a actuar. Se cambian en el nodo **Evaluar**.

## El campo que más importa es `timestamp`

Que un JSON diga «disco al 40 %» no significa que el servidor esté bien: puede ser la foto de hace tres días de un recolector que murió. Por eso cada JSON lleva la hora en que se generó, y tanto el dashboard como las alertas tratan como caído a un host cuyo último dato tiene más de 15 minutos (`staleSec`, `STALE_AFTER`).

Un host que no reporta **no** dispara además alertas de disco o RAM: con datos viejos esos números no significan nada. Llega un solo aviso, el de disponibilidad.

## Push al central, no un endpoint por servidor

Cada servidor empuja su JSON al central por SSH. La alternativa era que cada uno sirviera sus métricas por HTTP y el dashboard las fuera a buscar. Se descartó por dos razones:

- **Un solo origen:** el dashboard lee todo de su propio dominio. No hay CORS ni tres URLs con métricas de tus servidores expuestas, que serían información gratis para cualquiera que las encuentre.
- **Nada nuevo escuchando:** los servidores no abren ningún puerto. Usan el SSH que ya tenían.

La clave de cada servidor está atada a un solo comando (`command="metrics-recv srv-b",restrict,from=…`). El nombre del host lo pone el central, no el cliente, y `metrics-recv` rechaza un JSON cuyo `"host"` no coincida. Si te roban esa clave, lo único que se puede hacer con ella es publicar métricas falsas de ese servidor, y sólo desde su IP.

## El dead man's switch avisa por correo, no por Telegram

Las alertas salen de n8n, que corre en el central. Si el central se cae, las alertas se caen con él, y lo que llega es silencio, que se parece mucho a «está todo bien».

Por eso otro servidor, el vigía, consulta cada 5 minutos dos cosas:

1. `/healthz` de n8n: el central, el proxy y n8n responden.
2. Un webhook «latido» que devuelve la hora de la última corrida de las alertas. n8n puede estar vivo y el workflow no estar corriendo, y eso sólo se ve así.

Si falla, avisa **por correo, con el MTA del propio vigía**. No usa Telegram porque el bot vive en n8n y el webhook pasa por el central: sería pedirle al que se cayó que avise de su propia caída.

Avisa a las 2 fallas seguidas, para no saltar por un corte de red de un minuto. Mientras siga caído recuerda cada 6 horas y, cuando vuelve, avisa cuánto duró.

¿Y quién vigila al vigía? El propio monitoreo: si el vigía deja de reportar, las alertas del central avisan «srv-b no reporta».

## Sin base de datos

Todo es archivos: un JSON por servidor con la última foto y un `state.json` con los problemas abiertos. Opcionalmente hay un NDJSON por día y por host con cada muestra. Con pocos servidores, una base de datos sería una pieza más para mantener, respaldar y vigilar, y no aporta nada que haga falta para avisar.

Si necesitás series históricas y gráficos, esto no es la herramienta: usá Prometheus y Grafana.
