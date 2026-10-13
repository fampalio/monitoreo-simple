# Instalarlo con Claude

Pegá esto al comienzo de una conversación con Claude (o con el asistente que uses) y completá lo que está entre corchetes. Sirve para que te guíe paso a paso sin improvisar sobre tus servidores.

```
Voy a instalar monitoreo-simple (https://github.com/fampalio/monitoreo-simple) en mis
servidores. Leé el README del repo y guiame con estas reglas, sin excepciones:

1. Un paso por mensaje. Me das UN comando, lo ejecuto y te pego la salida real. No sigas
   hasta verla. Nunca asumas que un paso anterior salió bien.
2. Antes de modificar algo (archivo, cron, sshd, nginx, n8n), un comando de solo lectura que
   muestre cómo está hoy. No asumas rutas, versiones ni configuraciones.
3. En cada servidor nuevo, lo primero es `hostname -f` y `cat /etc/os-release`. Decime en qué
   servidor tiene que correr cada comando.
4. Ningún secreto en el chat: tokens, contraseñas y claves van en archivos .env en el servidor.
   Si hace falta uno, decime en qué archivo ponerlo; no me lo pidas en el chat.
5. Todo cambio en sshd o en el firewall tiene que tener vuelta atrás programada, y la sesión
   SSH actual tiene que seguir abierta hasta probar una nueva.
6. Seguimos el orden del README: relevar, recolector, receptor, sshd, transporte, dashboard,
   alertas, dead man's switch, prueba de fuego. No saltees la prueba de fuego.
7. Si algo no coincide con el README, decímelo y frená. No improvises.

Mis servidores: [nombre corto y rol de cada uno, sin IPs]
Cuál es el central (dashboard + n8n): [...]
Cuál vigila al central (dead man's switch): [...]
Cómo corre n8n en el central (systemd o Docker) y qué versión: [...]
```

Por qué cada regla: casi todo lo que sale mal en una instalación así sale mal **en silencio**. Un comando que "anduvo" pero no hizo nada, un workflow importado que nunca corrió, un sshd que recarga bien y te deja afuera en la próxima conexión. Ir de a un paso, viendo la salida real, es lo que lo hace visible a tiempo.
