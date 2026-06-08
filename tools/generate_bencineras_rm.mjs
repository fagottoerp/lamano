#!/usr/bin/env node

import { writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

const SOURCE_URL = 'https://preciobencina.cl/bencineras-en-region-metropolitana.php';
const OUTPUT_PATH = 'assets/bencineras_rm.json';

function decodeHtmlEntities(input) {
  if (!input) return '';
  return input
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/&#x([\da-fA-F]+);/g, (_, code) => String.fromCharCode(parseInt(code, 16)))
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');
}

function stripTags(input) {
  if (!input) return '';
  return decodeHtmlEntities(input.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function unescapeJs(input) {
  if (!input) return '';
  return input
    .replace(/\\n/g, ' ')
    .replace(/\\r/g, ' ')
    .replace(/\\t/g, ' ')
    .replace(/\\'/g, "'")
    .replace(/\\\"/g, '"')
    .replace(/\\\\/g, '\\');
}

function normalizeAddress(input) {
  return (input || '')
    .replace(/\s+/g, ' ')
    .replace(/^[-,\s]+|[-,\s]+$/g, '')
    .trim();
}

function titleCase(input) {
  return (input || '')
    .toLowerCase()
    .split(' ')
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

function fetchHtml() {
  const html = execFileSync(
    'curl',
    [
      '-L',
      '-s',
      '-A',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      SOURCE_URL,
    ],
    { encoding: 'utf8', maxBuffer: 1024 * 1024 * 64 },
  );

  if (!html || !html.includes('detalles-bencinera.php?i=')) {
    throw new Error('No se pudo descargar HTML util de Preciobencina.');
  }

  return html;
}

function parsePriceMap(popupHtml) {
  const out = {};
  const priceRe = /(Bencina\s*93|Bencina\s*95|Bencina\s*97|Diesel)\s*:\s*<strong>\$\s*([\d.]+)<\/strong>/gi;
  let m;
  while ((m = priceRe.exec(popupHtml)) !== null) {
    const label = m[1].toLowerCase().replace(/\s+/g, '_');
    out[label] = m[2].replace(/\./g, '');
  }
  return out;
}

function parseStations(html) {
  const stations = [];
  const markerRe = /L\.marker\(\[\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\],\{icon:\s*greenIcon\}\)\.addTo\(map\)\s*\.bindPopup\('([\s\S]*?)'\);/g;

  let m;
  while ((m = markerRe.exec(html)) !== null) {
    const lat = Number(m[1]);
    const lng = Number(m[2]);
    const popupHtml = unescapeJs(m[3]);

    if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;

    const brand = stripTags((popupHtml.match(/<h3[^>]*>([\s\S]*?)<\/h3>/i) || [])[1] || '');
    const address = normalizeAddress(
      stripTags((popupHtml.match(/lni-map-marker[^>]*><\/i>\s*([\s\S]*?)<\/h4>/i) || [])[1] || ''),
    );

    const href = ((popupHtml.match(/href="([^"]*detalles-bencinera\.php\?i=[^"]+)"/i) || [])[1] || '').trim();
    const detailUrlRaw = href.startsWith('http') ? href : `https://preciobencina.cl/${href.replace(/^\/+/, '')}`;
    const detailUrl = detailUrlRaw.trim();
    const stationId = (((detailUrl.match(/[?&]i=([^&]+)/i) || [])[1]) || '').trim();

    let comunaName = '';
    const titleAttr = decodeHtmlEntities((popupHtml.match(/title="([^"]+)"/i) || [])[1] || '');
    const comunaMatch = titleAttr.match(/,\s*([^,"]+)\s*$/);
    if (comunaMatch) {
      comunaName = titleCase(comunaMatch[1].trim());
    }

    const fuelPrices = parsePriceMap(popupHtml);

    stations.push({
      stationId,
      name: brand || 'Bencinera',
      lat,
      lng,
      regionName: 'Región Metropolitana',
      comunaName,
      institution: 'BENCINERA',
      brand: brand || '',
      address,
      detailUrl,
      fuelPrices,
    });
  }

  const unique = new Map();
  for (const st of stations) {
    const key = st.stationId || `${st.lat},${st.lng}`;
    if (!unique.has(key)) unique.set(key, st);
  }

  return [...unique.values()].sort((a, b) => {
    const c = a.comunaName.localeCompare(b.comunaName, 'es');
    if (c !== 0) return c;
    return a.name.localeCompare(b.name, 'es');
  });
}

async function main() {
  console.log('Descargando listado de bencineras RM...');
  const html = fetchHtml();
  const stations = parseStations(html);

  const payload = {
    source: SOURCE_URL,
    generatedAt: new Date().toISOString(),
    totalScraped: stations.length,
    stations,
  };

  await writeFile(OUTPUT_PATH, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

  console.log(`OK: ${OUTPUT_PATH}`);
  console.log(`Bencineras guardadas: ${stations.length}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
