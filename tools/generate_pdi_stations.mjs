#!/usr/bin/env node

import { writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

const SOURCE_URL = 'https://www.pdichile.cl/pdi-mas-cercano';
const OUTPUT_PATH = 'assets/pdi_stations.json';
const USER_AGENT = 'LamanoPDIMapper/1.0 (contacto: admin@lamano.cl)';

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
  return decodeHtmlEntities(input.replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizeAddress(address) {
  return address
    .replace(/\s*\([^)]*\)\s*/g, ' ')
    .replace(/N\s*°\s*/gi, ' ')
    .replace(/N\s*º\s*/gi, ' ')
    .replace(/\./g, ' ')
    .replace(/\bS\/N\b/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchHtml() {
  try {
    const res = await fetch(SOURCE_URL, {
      headers: {
        'User-Agent': USER_AGENT,
        Accept: 'text/html,application/xhtml+xml',
      },
    });
    if (res.ok) {
      return res.text();
    }
  } catch (_) {
    // Fallback below.
  }

  const curlHtml = execFileSync(
    'curl',
    [
      '-L',
      '-s',
      '-A',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      SOURCE_URL,
    ],
    { encoding: 'utf8' },
  );

  if (!curlHtml || !curlHtml.includes('menu-pdi-mas-cercano')) {
    throw new Error('No se pudo descargar HTML util de PDI (fetch/curl bloqueados).');
  }

  return curlHtml;
}

function parseUnitComunaMap(html) {
  const map = new Map();
  const re = /<li[^>]*data-comuna="([^"]*)"[^>]*data-unidad="(unidad_[^"]+)"[^>]*data-unidad-titulo="([^"]*)"[^>]*>/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    const comuna = stripTags(m[1]);
    const unidadId = stripTags(m[2]);
    const unitTitle = stripTags(m[3]);
    map.set(unidadId, { comuna, unitTitle });
  }
  return map;
}

function parseCards(html, unitMap) {
  const cards = [];
  const chunks = html.split(/<div\s+id="unidadDetail_/gi).slice(1);

  for (const chunk of chunks) {
    const guid = (chunk.match(/^([\da-f\-]{36})"/i) || [])[1];
    if (!guid) continue;

    const block = `<div id="unidadDetail_${chunk}`;
    const stationId = `unidad_${guid}`;

    const name = stripTags((block.match(/<h3>([\s\S]*?)<\/h3>/i) || [])[1] || '');
    const address = normalizeAddress(
      stripTags((block.match(/<div class="direccion">[\s\S]*?<br>\s*([\s\S]*?)\s*<\/div>/i) || [])[1] || ''),
    );
    const regionName = stripTags((block.match(/<h5>\s*([\s\S]*?)\s*<\/h5>/i) || [])[1] || '');
    const regionAddress = normalizeAddress(
      stripTags((block.match(/<strong>Dirección:<\/strong>\s*([\s\S]*?)\s*<\/div>/i) || [])[1] || ''),
    );

    const unitInfo = unitMap.get(stationId) || { comuna: '', unitTitle: '' };

    cards.push({
      stationId,
      name: name || unitInfo.unitTitle || stationId,
      comunaName: unitInfo.comuna || '',
      regionName: regionName.replace(/^Regi[oó]n\s+Policial\s+de\s+/i, 'Región de ').trim(),
      address,
      regionAddress,
    });
  }

  return cards;
}

async function geocode(query) {
  const url = new URL('https://nominatim.openstreetmap.org/search');
  url.searchParams.set('format', 'jsonv2');
  url.searchParams.set('limit', '1');
  url.searchParams.set('countrycodes', 'cl');
  url.searchParams.set('accept-language', 'es');
  url.searchParams.set('q', query);

  const res = await fetch(url, {
    headers: {
      'User-Agent': USER_AGENT,
      Accept: 'application/json',
    },
  });
  if (!res.ok) return null;

  const data = await res.json();
  if (!Array.isArray(data) || data.length === 0) return null;

  const top = data[0];
  const lat = Number(top.lat);
  const lng = Number(top.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;

  return { lat, lng };
}

async function geocodeAll(stations) {
  const cache = new Map();
  let resolved = 0;

  for (let i = 0; i < stations.length; i += 1) {
    const st = stations[i];
    const queries = [
      [st.name, st.comunaName, st.regionName, 'Chile'].filter(Boolean).join(', '),
      [st.address, st.comunaName, st.regionName, 'Chile'].filter(Boolean).join(', '),
      [st.address, st.comunaName, 'Chile'].filter(Boolean).join(', '),
      [st.regionAddress, st.regionName, 'Chile'].filter(Boolean).join(', '),
    ].filter((q) => q.length > 0);

    let coords = null;

    for (const query of queries) {
      if (!query) continue;
      if (cache.has(query)) {
        coords = cache.get(query);
        if (coords) break;
        continue;
      }

      coords = await geocode(query);
      cache.set(query, coords);
      await delay(1100);
      if (coords) break;
    }

    if (coords) {
      st.lat = coords.lat;
      st.lng = coords.lng;
      resolved += 1;
    }

    if ((i + 1) % 20 === 0 || i + 1 === stations.length) {
      console.log(`Geocodificadas ${i + 1}/${stations.length} (resueltas: ${resolved})`);
    }
  }

  return resolved;
}

async function main() {
  console.log('Descargando listado PDI...');
  const html = await fetchHtml();

  const unitMap = parseUnitComunaMap(html);
  const cards = parseCards(html, unitMap);
  console.log(`Unidades encontradas: ${cards.length}`);

  const uniqueById = new Map(cards.map((c) => [c.stationId, c]));
  const stations = [...uniqueById.values()];

  console.log('Iniciando geocodificación (Nominatim)...');
  const resolved = await geocodeAll(stations);

  const finalStations = stations
    .filter((s) => Number.isFinite(s.lat) && Number.isFinite(s.lng))
    .map((s) => ({
      stationId: s.stationId,
      name: s.name,
      lat: s.lat,
      lng: s.lng,
      regionName: s.regionName,
      comunaName: s.comunaName,
      institution: 'PDI',
      address: s.address,
    }))
    .sort((a, b) => a.regionName.localeCompare(b.regionName, 'es'));

  const payload = {
    source: SOURCE_URL,
    generatedAt: new Date().toISOString(),
    totalScraped: stations.length,
    totalGeocoded: resolved,
    stations: finalStations,
  };

  await writeFile(OUTPUT_PATH, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

  console.log(`OK: ${OUTPUT_PATH}`);
  console.log(`Scrapeadas: ${stations.length} | Geocodificadas: ${resolved} | Guardadas: ${finalStations.length}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
