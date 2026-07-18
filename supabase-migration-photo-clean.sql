-- =====================================================================
-- Sabores Royal — Guardar la foto "limpia" (sin sello Sin TACC) aparte
-- =====================================================================
-- Antes, el sello Sin TACC se aplanaba directo en los píxeles de la
-- foto final y se guardaba así — una vez guardado, apagar el toggle no
-- tenía de dónde recuperar la versión sin sello (es una edición
-- destructiva, como aplanar capas en Photoshop). Esta columna guarda
-- esa versión limpia por separado la próxima vez que se suba/edite una
-- foto, para que el toggle se pueda prender y apagar sin perder nada.
--
-- No hace nada retroactivo con fotos ya guardadas con el sello puesto
-- de antes de este cambio — esas van a necesitar volver a subirse una
-- vez para "resetear" y quedar editables de nuevo.
--
-- Aditivo, seguro de correr más de una vez.
-- =====================================================================

ALTER TABLE products ADD COLUMN IF NOT EXISTS photo_clean_url text;
