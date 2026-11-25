// Service Worker inerte para Decidim.
//
// Contexto: el Service Worker de Decidim (Workbox) precachea ~172 assets al
// instalarse. En este despliegue, el rate limit de nginx devuelve 503 a parte
// de esas peticiones, la instalacion falla y el SW queda roto: intercepta las
// peticiones y devuelve error, por lo que no carga decidim_core.js (rails-ujs)
// y los enlaces con data-method="post" se comportan como GET.
// (Sintoma: "Not found. Authentication passthru." al pulsar el boton de Enzona.)
//
// Este SW no registra ningun handler de "fetch", asi que el navegador no
// enruta peticiones a traves de el. Solo limpia la cache del SW anterior y
// toma el control de las pestanas abiertas.
//
// Lo que se pierde: notificaciones push (no configuradas: no hay claves
// VAPID) y la pagina offline. El resto del sitio no se ve afectado.

self.addEventListener("install", (event) => {
  // Activar en cuanto este listo, sin esperar a que se cierren las pestanas.
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      // Borrar la precache que dejo el Service Worker roto anterior.
      const cacheKeys = await caches.keys();
      await Promise.all(cacheKeys.map((key) => caches.delete(key)));

      // Tomar el control de las pestanas ya abiertas.
      await self.clients.claim();
    })()
  );
});

// InjectManifest de webpack exige un punto de inyeccion para el manifest.
// Se ignora a proposito: no queremos precachear nada.
// eslint-disable-next-line no-unused-vars
const ignoredPrecacheManifest = self.__WB_MANIFEST;
