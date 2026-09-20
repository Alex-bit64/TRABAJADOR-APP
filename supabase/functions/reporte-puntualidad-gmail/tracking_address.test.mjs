import assert from "node:assert/strict";
import test from "node:test";

import {
  claveCoordenadas,
  direccionCoordenadas,
  direccionGeocodificada,
  direccionMarca,
  obtenerCoordenadas,
} from "./tracking_address.ts";

test("la marca de Bryan mantiene las coordenadas de El Polo", () => {
  const coordenadas = obtenerCoordenadas({
    latitud: -12.101599,
    longitud: -76.9711231,
  });
  assert.deepEqual(coordenadas, {
    latitud: -12.101599,
    longitud: -76.9711231,
  });
  assert.equal(claveCoordenadas(coordenadas), "-12.1016,-76.9711");
  assert.equal(
    direccionCoordenadas(coordenadas),
    "-12.101599, -76.971123 (ver mapa)",
  );
  assert.equal(
    direccionMarca(coordenadas),
    "-12.101599, -76.971123 (ver mapa)",
  );
  assert.equal(
    direccionMarca(
      coordenadas,
      "Avenida El Polo, Monterrico, Santiago de Surco (aprox.)",
    ),
    "Avenida El Polo, Monterrico, Santiago de Surco (aprox.)",
  );
});

test("usa la calle de la marca devuelta por geocodificacion", () => {
  assert.equal(
    direccionGeocodificada({
      address: {
        road: "Avenida El Polo",
        suburb: "Monterrico",
        city: "Santiago de Surco",
      },
    }),
    "Avenida El Polo, Monterrico, Santiago de Surco",
  );
  assert.equal(direccionGeocodificada({ address: {} }), null);
});

test("ignora coordenadas ausentes o invalidas", () => {
  assert.equal(obtenerCoordenadas(null), null);
  assert.equal(obtenerCoordenadas({ latitud: "", longitud: "" }), null);
  assert.equal(obtenerCoordenadas({ latitud: 100, longitud: -76 }), null);
});
