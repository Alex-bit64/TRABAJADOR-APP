import "@supabase/functions-js/edge-runtime.d.ts";

import { createClient } from "@supabase/supabase-js";
import nodemailer from "nodemailer";

type ReporteTipo = "TIENDA" | "GENERAL";

type Configuracion = {
  id_config: string;
  id_tienda: string | null;
  correo_destino: string;
  minutos_tolerancia: number;
  activo: boolean;
  tipo_reporte: ReporteTipo;
  nombre_reporte: string;
  hora_envio: string;
  ventana_minutos: number;
};

type Tienda = {
  id_tienda: string;
  nombre: string;
  direccion?: string | null;
  estado?: boolean;
};

type Trabajador = {
  dni: string;
  id_tienda: string | null;
  nombre: string | null;
  cargo: string | null;
  telefono: string | null;
  estado: boolean;
};

type Asistencia = {
  dni_trabajador: string;
  fecha: string;
  horario_entrada: string | null;
  horario_inicio_receso: string | null;
  horario_fin_receso: string | null;
  horario_salida: string | null;
};

type Horario = {
  dni_trabajador: string;
  dia_semana: string;
  horario_entrada: string | null;
};

type ContextoReporte = {
  trabajadores: Trabajador[];
  asistenciaPorDni: Map<string, Asistencia>;
  horarioPorDni: Map<string, Horario>;
  tiendaPorId: Map<string, Tienda>;
  trackingPorDni: Map<string, TrackingMarca[]>;
};

type TrackingMarca = {
  id: number;
  id_trabajador: string;
  id_tienda: string | null;
  hora_marca: string;
  ubicacion: Record<string, unknown> | null;
  tipo: "NORMAL" | "MULTIPLE" | string;
};

type TrackingDetalle = {
  dni_trabajador: string;
  nombre_trabajador: string;
  lugar: string;
  direccion: string;
  evento: string;
  hora: string;
  enlace_mapa: string | null;
  tipo: string;
};

type SeccionTienda = {
  tienda: Tienda;
  pendientes: TrabajadorPendiente[];
  tracking: TrackingDetalle[];
};

type TrabajadorPendiente = {
  dni_trabajador: string;
  nombre_trabajador: string;
  telefono: string;
  cargo: string;
  id_tienda: string;
  nombre_tienda: string;
  tipo_marcacion: "Entrada";
  hora_programada: string;
  hora_marcada: string | null;
  minutos_tarde: number | null;
  motivo: string;
};

type RequestBody = {
  trigger?: string;
  fecha?: string;
  hora_envio?: string;
  tipo_reporte?: ReporteTipo;
  id_config?: string;
  id_tienda?: string;
  correo_destino?: string;
  correo_prueba?: string;
  enviar_vacios?: boolean;
  dry_run?: boolean;
  modo_prueba?: boolean;
};

const zonaHoraria = "America/Lima";
const supabaseUrl = requiredEnv("SUPABASE_URL");
const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
const gmailUser = requiredEnv("GMAIL_USER");
const gmailPassword = requiredEnv("GMAIL_APP_PASSWORD");
const gmailFromName = Deno.env.get("GMAIL_FROM_NAME") ?? "GMA Negocios";
const smtpHost = Deno.env.get("GMAIL_SMTP_HOST") ?? "smtp.gmail.com";
const smtpPort = Number(Deno.env.get("GMAIL_SMTP_PORT") ?? "465");
const smtpSecure = (Deno.env.get("GMAIL_SMTP_SECURE") ?? "true") !== "false";
const cronSecret = requiredEnv("CRON_SECRET").trim();

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

const transporter = nodemailer.createTransport({
  host: smtpHost,
  port: smtpPort,
  secure: smtpSecure,
  auth: {
    user: gmailUser,
    pass: gmailPassword,
  },
});

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return json({ ok: false, error: "Metodo no permitido." }, 405);
    }

    const recibido = req.headers.get("x-cron-secret")?.trim() ?? "";
    if (recibido !== cronSecret) {
      return json({ ok: false, error: "No autorizado." }, 401);
    }

    const body = await readBody(req);
    const fecha = body.fecha ?? fechaLima();
    const horaActual = horaLimaActual();
    const enviarVacios = body.enviar_vacios ?? true;

    const todasLasConfigs = await consultarConfiguraciones({});
    const configsCoincidentes = filtrarConfiguracionesSolicitud(
      todasLasConfigs,
      body,
    );
    const configsDebidas = seleccionarConfiguracionesPorHora(
      configsCoincidentes,
      body,
      horaActual,
    );
    const automatico = body.trigger === "cron" && !body.correo_prueba;
    const configs = automatico
      ? await excluirConfiguracionesEnviadas(configsDebidas, fecha)
      : configsDebidas;
    const incluirTracking = configs.some((config) =>
      esUltimoReporteDelArea(config, todasLasConfigs)
    );
    const contexto = configs.length > 0
      ? await cargarContextoReporte(fecha, incluirTracking)
      : contextoVacio();
    const resultados = await Promise.all(
      configs.map((config) =>
        procesarConfiguracion({
          config,
          todasLasConfigs,
          contexto,
          fecha,
          correoOverride: body.correo_prueba,
          enviarVacios,
          dryRun: body.dry_run ?? false,
          modoPrueba: body.modo_prueba ?? false,
        })
      ),
    );

    return json({
      ok: true,
      fecha,
      hora_actual: horaActual,
      hora_envio_solicitada: body.hora_envio
        ? normalizarHora(body.hora_envio)
        : null,
      configuraciones_debidas: configsDebidas.length,
      omitidas_ya_enviadas: configsDebidas.length - configs.length,
      configuraciones: configs.length,
      resultados,
    });
  } catch (error) {
    console.error("reporte-puntualidad-gmail", error);
    return json(
      {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      },
      500,
    );
  }
});

function filtrarConfiguracionesSolicitud(
  configs: Configuracion[],
  body: RequestBody,
) {
  const correoFiltro = normalizarCorreo(body.correo_destino);
  return configs.filter((config) =>
    (!body.id_config || config.id_config === body.id_config) &&
    (!body.tipo_reporte || config.tipo_reporte === body.tipo_reporte) &&
    (!body.id_tienda || config.id_tienda === body.id_tienda) &&
    (!correoFiltro ||
      normalizarCorreo(config.correo_destino) === correoFiltro)
  );
}

async function consultarConfiguraciones(params: {
  idConfig?: string;
  tipoReporte?: ReporteTipo;
  idTienda?: string;
  correoDestino?: string;
}) {
  let query = supabase
    .from("alerta_puntualidad_config")
    .select(
      "id_config,id_tienda,correo_destino,minutos_tolerancia,activo,tipo_reporte,nombre_reporte,hora_envio,ventana_minutos",
    )
    .eq("activo", true);

  if (params.idConfig) {
    query = query.eq("id_config", params.idConfig);
  }
  if (params.tipoReporte) {
    query = query.eq("tipo_reporte", params.tipoReporte);
  }
  if (params.idTienda) {
    query = query.eq("id_tienda", params.idTienda);
  }

  const { data, error } = await query
    .order("hora_envio", { ascending: true })
    .order("tipo_reporte", { ascending: true });
  if (error) {
    throw new Error(
      `No se pudo leer alerta_puntualidad_config: ${error.message}`,
    );
  }

  const configs = (data ?? []) as Configuracion[];
  const correoFiltro = normalizarCorreo(params.correoDestino);
  if (!correoFiltro) {
    return configs;
  }

  return configs.filter((config) =>
    normalizarCorreo(config.correo_destino) === correoFiltro
  );
}

function seleccionarConfiguracionesPorHora(
  configs: Configuracion[],
  body: RequestBody,
  horaActual: string,
) {
  if (body.hora_envio) {
    const horaSolicitada = normalizarHora(body.hora_envio);
    return configs.filter((config) =>
      normalizarHora(config.hora_envio) === horaSolicitada
    );
  }

  if (body.trigger !== "cron" && body.id_config) {
    return configs;
  }

  const minutoActual = minutosDesdeHora(horaActual);
  return configs.filter((config) => {
    const minutoProgramado = minutosDesdeHora(config.hora_envio);
    const diferencia = minutoActual - minutoProgramado;
    return diferencia >= 0 && diferencia < config.ventana_minutos;
  });
}

async function excluirConfiguracionesEnviadas(
  configs: Configuracion[],
  fecha: string,
) {
  if (configs.length === 0) {
    return [];
  }

  const { data, error } = await supabase
    .from("alerta_puntualidad_log")
    .select("id_config,hora_envio")
    .eq("fecha", fecha)
    .eq("enviado", true)
    .in("id_config", configs.map((config) => config.id_config));
  if (error) {
    throw new Error(`No se pudo comprobar envios previos: ${error.message}`);
  }

  const enviados = new Set(
    (data ?? []).map((item) =>
      `${item.id_config}:${normalizarHora(item.hora_envio)}`
    ),
  );
  return configs.filter((config) =>
    !enviados.has(
      `${config.id_config}:${normalizarHora(config.hora_envio)}`,
    )
  );
}

async function procesarConfiguracion(params: {
  config: Configuracion;
  todasLasConfigs: Configuracion[];
  contexto: ContextoReporte;
  fecha: string;
  correoOverride?: string;
  enviarVacios: boolean;
  dryRun: boolean;
  modoPrueba: boolean;
}) {
  const {
    config,
    todasLasConfigs,
    contexto,
    fecha,
    correoOverride,
    enviarVacios,
    dryRun,
    modoPrueba,
  } = params;
  const destino = correoOverride?.trim() || config.correo_destino;
  const tienda = config.id_tienda
    ? contexto.tiendaPorId.get(config.id_tienda) ?? null
    : null;
  const trabajadores = config.tipo_reporte === "GENERAL"
    ? contexto.trabajadores
    : contexto.trabajadores.filter((trabajador) =>
      trabajador.id_tienda === config.id_tienda
    );
  const horaAnterior = obtenerHoraAnterior(config, todasLasConfigs);
  const pendientes = calcularPendientes({
    trabajadores,
    contexto,
    tolerancia: config.minutos_tolerancia,
    horaEnvio: config.hora_envio,
    horaAnterior,
  });
  const incluirTracking = esUltimoReporteDelArea(config, todasLasConfigs);
  const secciones = construirSeccionesTienda({
    config,
    contexto,
    pendientes,
    incluirTracking,
  });
  const tituloReporte = config.tipo_reporte === "GENERAL"
    ? "GENERAL"
    : tienda?.nombre ?? "Tienda";
  const html = renderHtml({
    tituloReporte,
    config,
    fecha,
    secciones,
    incluirTracking,
  });
  const text = renderTexto({
    tituloReporte,
    config,
    fecha,
    secciones,
    incluirTracking,
  });

  let enviado = false;
  let error: string | null = null;

  if (!dryRun && (pendientes.length > 0 || enviarVacios)) {
    try {
      await transporter.sendMail({
        from: `"${gmailFromName}" <${gmailUser}>`,
        to: destino,
        subject: `${
          modoPrueba ? "[PRUEBA] " : ""
        }Alertas de puntualidad - ${tituloReporte} - ${config.nombre_reporte}`,
        html,
        text,
      });
      enviado = true;
    } catch (sendError) {
      error = sendError instanceof Error
        ? sendError.message
        : String(sendError);
      console.error("Error enviando correo", {
        id_config: config.id_config,
        destino,
        error,
      });
    }
  }

  if (!dryRun && !modoPrueba) {
    await guardarLog({
      config,
      fecha,
      destino,
      pendientes,
      enviado,
      error,
    });
  }

  return {
    id_config: config.id_config,
    tipo_reporte: config.tipo_reporte,
    id_tienda: config.id_tienda,
    correo_destino: destino,
    total_trabajadores: pendientes.length,
    desde_hora_anterior: horaAnterior,
    simulacion: dryRun,
    modo_prueba: modoPrueba,
    incluye_tracking: incluirTracking,
    total_marcas_tracking: secciones.reduce(
      (total, seccion) => total + seccion.tracking.length,
      0,
    ),
    trabajadores: dryRun ? pendientes : undefined,
    tiendas: dryRun
      ? secciones.map((seccion) => ({
        id_tienda: seccion.tienda.id_tienda,
        nombre: seccion.tienda.nombre,
        pendientes: seccion.pendientes.length,
        marcas_tracking: seccion.tracking.length,
      }))
      : undefined,
    enviado,
    error,
  };
}

function esUltimoReporteDelArea(
  config: Configuracion,
  configs: Configuracion[],
) {
  const horaConfig = minutosDesdeHora(config.hora_envio);
  return !configs.some((item) =>
    item.tipo_reporte === config.tipo_reporte &&
    item.id_tienda === config.id_tienda &&
    minutosDesdeHora(item.hora_envio) > horaConfig
  );
}

function construirSeccionesTienda(params: {
  config: Configuracion;
  contexto: ContextoReporte;
  pendientes: TrabajadorPendiente[];
  incluirTracking: boolean;
}): SeccionTienda[] {
  const { config, contexto, pendientes, incluirTracking } = params;
  const tiendas = config.tipo_reporte === "GENERAL"
    ? [...contexto.tiendaPorId.values()]
      .filter((item) => item.estado !== false)
      .sort((a, b) => a.nombre.localeCompare(b.nombre, "es"))
    : [
      contexto.tiendaPorId.get(config.id_tienda ?? "") ?? {
        id_tienda: config.id_tienda ?? "",
        nombre: "Tienda",
        direccion: "",
      },
    ];

  return tiendas.map((tienda) => {
    const trabajadores = contexto.trabajadores.filter((item) =>
      item.id_tienda === tienda.id_tienda
    );
    const dnis = new Set(trabajadores.map((item) => item.dni));
    return {
      tienda,
      pendientes: pendientes.filter((item) =>
        item.id_tienda === tienda.id_tienda
      ),
      tracking: incluirTracking
        ? construirTracking(trabajadores, contexto, dnis)
        : [],
    };
  });
}

function construirTracking(
  trabajadores: Trabajador[],
  contexto: ContextoReporte,
  dnis: Set<string>,
) {
  const trabajadorPorDni = new Map(
    trabajadores.map((item) => [item.dni, item]),
  );
  const resultado: TrackingDetalle[] = [];

  for (const dni of dnis) {
    const trabajador = trabajadorPorDni.get(dni);
    const marcas = [...(contexto.trackingPorDni.get(dni) ?? [])]
      .sort((a, b) =>
        new Date(a.hora_marca).getTime() - new Date(b.hora_marca).getTime()
      );
    const conteoPorLugar = new Map<string, number>();

    for (const marca of marcas) {
      const idLugar = marca.id_tienda ?? "";
      const tiendaVisitada = contexto.tiendaPorId.get(idLugar);
      const numeroLugar = conteoPorLugar.get(idLugar) ?? 0;
      const evento = eventoTracking(
        marca,
        contexto.asistenciaPorDni.get(dni),
        numeroLugar,
      );
      conteoPorLugar.set(idLugar, numeroLugar + 1);
      const coordenadas = obtenerCoordenadas(marca.ubicacion);

      resultado.push({
        dni_trabajador: dni,
        nombre_trabajador: trabajador?.nombre?.trim() || "Sin nombre",
        lugar: tiendaVisitada?.nombre ?? "Ubicacion no identificada",
        direccion: tiendaVisitada?.direccion?.trim() ||
          "Direccion no registrada",
        evento,
        hora: horaLima(marca.hora_marca),
        enlace_mapa: coordenadas
          ? `https://www.google.com/maps?q=${coordenadas.latitud},${coordenadas.longitud}`
          : null,
        tipo: marca.tipo,
      });
    }
  }

  return resultado.sort((a, b) =>
    a.nombre_trabajador.localeCompare(b.nombre_trabajador, "es") ||
    a.hora.localeCompare(b.hora)
  );
}

function eventoTracking(
  marca: TrackingMarca,
  asistencia: Asistencia | undefined,
  numeroLugar: number,
) {
  if (marca.tipo === "NORMAL" && asistencia) {
    const campos: Array<[string | null, string]> = [
      [asistencia.horario_entrada, "Entrada"],
      [asistencia.horario_inicio_receso, "Inicio de receso"],
      [asistencia.horario_fin_receso, "Fin de receso"],
      [asistencia.horario_salida, "Salida"],
    ];
    const instante = new Date(marca.hora_marca).getTime();
    const coincidencia = campos.find(([valor]) =>
      valor && Math.abs(new Date(valor).getTime() - instante) < 1000
    );
    if (coincidencia) {
      return coincidencia[1];
    }
    return "Marca de asistencia";
  }

  return numeroLugar % 2 === 0
    ? "Llegada (segun orden de marcas)"
    : "Salida (segun orden de marcas)";
}

function obtenerCoordenadas(ubicacion: Record<string, unknown> | null) {
  if (!ubicacion) {
    return null;
  }
  const latitud = Number(ubicacion.latitud ?? ubicacion.latitude);
  const longitud = Number(ubicacion.longitud ?? ubicacion.longitude);
  return Number.isFinite(latitud) && Number.isFinite(longitud)
    ? { latitud, longitud }
    : null;
}

async function cargarContextoReporte(
  fecha: string,
  incluirTracking: boolean,
): Promise<ContextoReporte> {
  const { data, error } = await supabase
    .from("trabajador")
    .select("dni,id_tienda,nombre,cargo,telefono,estado")
    .eq("estado", true)
    .order("nombre", { ascending: true });
  if (error) {
    throw new Error(`No se pudo leer trabajador: ${error.message}`);
  }

  const trabajadores = (data ?? []) as Trabajador[];
  if (trabajadores.length === 0) {
    return contextoVacio();
  }

  const dnis = trabajadores.map((item) => item.dni);
  const tiendasIds = [
    ...new Set(
      trabajadores
        .map((item) => item.id_tienda)
        .filter((value): value is string => Boolean(value)),
    ),
  ];
  const [asistencias, horarios, tiendas, tracking] = await Promise.all([
    obtenerAsistencias(dnis, fecha),
    obtenerHorarios(dnis, diaSemanaLima(fecha)),
    obtenerTiendas(tiendasIds, true),
    incluirTracking ? obtenerTracking(dnis, fecha) : Promise.resolve([]),
  ]);

  return {
    trabajadores,
    asistenciaPorDni: new Map(
      asistencias.map((item) => [item.dni_trabajador, item]),
    ),
    horarioPorDni: new Map(
      horarios.map((item) => [item.dni_trabajador, item]),
    ),
    tiendaPorId: new Map(
      tiendas.map((item) => [item.id_tienda, item]),
    ),
    trackingPorDni: agruparTracking(tracking),
  };
}

function contextoVacio(): ContextoReporte {
  return {
    trabajadores: [],
    asistenciaPorDni: new Map(),
    horarioPorDni: new Map(),
    tiendaPorId: new Map(),
    trackingPorDni: new Map(),
  };
}

function calcularPendientes(params: {
  trabajadores: Trabajador[];
  contexto: ContextoReporte;
  tolerancia: number;
  horaEnvio: string;
  horaAnterior: string | null;
}): TrabajadorPendiente[] {
  const {
    trabajadores,
    contexto,
    tolerancia,
    horaEnvio,
    horaAnterior,
  } = params;
  if (trabajadores.length === 0) {
    return [];
  }

  const horaReporteMinutos = minutosDesdeHora(horaEnvio);
  const reporteAnteriorMinutos = horaAnterior == null
    ? -1
    : minutosDesdeHora(horaAnterior);
  const pendientes: TrabajadorPendiente[] = [];

  for (const trabajador of trabajadores) {
    const horario = contexto.horarioPorDni.get(trabajador.dni);
    if (!horario?.horario_entrada) {
      continue;
    }

    const asistencia = contexto.asistenciaPorDni.get(trabajador.dni);
    const horaProgramada = normalizarHora(horario.horario_entrada);
    const horaProgramadaMinutos = minutosDesdeHora(horaProgramada);
    const limiteToleranciaMinutos = horaProgramadaMinutos + tolerancia;
    if (
      limiteToleranciaMinutos <= reporteAnteriorMinutos ||
      limiteToleranciaMinutos > horaReporteMinutos
    ) {
      continue;
    }

    const horaMarcada = asistencia?.horario_entrada
      ? horaLima(asistencia.horario_entrada)
      : null;
    const horaMarcadaMinutos = asistencia?.horario_entrada
      ? minutosDesdeFechaLima(asistencia.horario_entrada)
      : null;

    let motivo: string | null = null;
    let minutosTarde: number | null = null;

    if (horaMarcadaMinutos == null) {
      motivo = "No marco entrada dentro de la tolerancia.";
    } else {
      minutosTarde = horaMarcadaMinutos - horaProgramadaMinutos;
      if (minutosTarde <= tolerancia) {
        continue;
      }
      motivo = `Marco entrada ${minutosTarde} minutos tarde.`;
    }

    const idTienda = trabajador.id_tienda ?? "";
    pendientes.push({
      dni_trabajador: trabajador.dni,
      nombre_trabajador: trabajador.nombre?.trim() || "Sin nombre",
      telefono: trabajador.telefono?.trim() || "",
      cargo: trabajador.cargo?.trim() || "",
      id_tienda: idTienda,
      nombre_tienda: contexto.tiendaPorId.get(idTienda)?.nombre ?? "Tienda",
      tipo_marcacion: "Entrada",
      hora_programada: horaProgramada.slice(0, 5),
      hora_marcada: horaMarcada,
      minutos_tarde: minutosTarde,
      motivo,
    });
  }

  return pendientes;
}

function obtenerHoraAnterior(
  config: Configuracion,
  configs: Configuracion[],
) {
  const horaActualMinutos = minutosDesdeHora(config.hora_envio);
  const horasAnteriores = configs
    .filter((item) =>
      item.tipo_reporte === config.tipo_reporte &&
      item.id_tienda === config.id_tienda &&
      normalizarCorreo(item.correo_destino) ===
        normalizarCorreo(config.correo_destino) &&
      minutosDesdeHora(item.hora_envio) < horaActualMinutos
    )
    .map((item) => normalizarHora(item.hora_envio))
    .sort((a, b) => minutosDesdeHora(b) - minutosDesdeHora(a));
  return horasAnteriores[0] ?? null;
}

async function obtenerAsistencias(dnis: string[], fecha: string) {
  const { data, error } = await supabase
    .from("asistencia")
    .select(
      "dni_trabajador,fecha,horario_entrada,horario_inicio_receso,horario_fin_receso,horario_salida",
    )
    .eq("fecha", fecha)
    .in("dni_trabajador", dnis);
  if (error) {
    throw new Error(`No se pudo leer asistencia: ${error.message}`);
  }
  return (data ?? []) as Asistencia[];
}

async function obtenerHorarios(dnis: string[], diaSemana: string) {
  const { data, error } = await supabase
    .from("horario_trabajador")
    .select("dni_trabajador,dia_semana,horario_entrada")
    .eq("dia_semana", diaSemana)
    .in("dni_trabajador", dnis);
  if (error) {
    throw new Error(`No se pudo leer horario_trabajador: ${error.message}`);
  }
  return (data ?? []) as Horario[];
}

async function obtenerTiendas(ids: string[], incluirTodas = false) {
  if (ids.length === 0 && !incluirTodas) {
    return [];
  }

  let query = supabase
    .from("tienda")
    .select("id_tienda,nombre,direccion,estado");
  if (!incluirTodas) {
    query = query.in("id_tienda", ids);
  }
  const { data, error } = await query.order("nombre", { ascending: true });
  if (error) {
    throw new Error(`No se pudo leer tienda: ${error.message}`);
  }
  return (data ?? []) as Tienda[];
}

async function obtenerTracking(dnis: string[], fecha: string) {
  if (dnis.length === 0) {
    return [];
  }
  const inicio = new Date(`${fecha}T00:00:00-05:00`);
  const fin = new Date(inicio.getTime() + 24 * 60 * 60 * 1000);
  const { data, error } = await supabase
    .from("asistencia_multiple")
    .select("id,id_trabajador,id_tienda,hora_marca,ubicacion,tipo")
    .in("id_trabajador", dnis)
    .gte("hora_marca", inicio.toISOString())
    .lt("hora_marca", fin.toISOString())
    .order("hora_marca", { ascending: true });
  if (error) {
    throw new Error(`No se pudo leer asistencia_multiple: ${error.message}`);
  }
  return (data ?? []) as TrackingMarca[];
}

function agruparTracking(items: TrackingMarca[]) {
  const resultado = new Map<string, TrackingMarca[]>();
  for (const item of items) {
    const lista = resultado.get(item.id_trabajador) ?? [];
    lista.push(item);
    resultado.set(item.id_trabajador, lista);
  }
  return resultado;
}

async function guardarLog(params: {
  config: Configuracion;
  fecha: string;
  destino: string;
  pendientes: TrabajadorPendiente[];
  enviado: boolean;
  error: string | null;
}) {
  const { config, fecha, destino, pendientes, enviado, error } = params;
  const payload = {
    id_config: config.id_config,
    id_tienda: config.id_tienda,
    fecha,
    tipo_reporte: config.tipo_reporte,
    nombre_reporte: config.nombre_reporte,
    hora_envio: config.hora_envio,
    correo_destino: destino,
    minutos_tolerancia: config.minutos_tolerancia,
    total_trabajadores: pendientes.length,
    trabajadores: pendientes,
    enviado,
    error,
    enviado_en: enviado ? new Date().toISOString() : null,
  };

  const { data: existente, error: buscarError } = await supabase
    .from("alerta_puntualidad_log")
    .select("id_log")
    .eq("id_config", config.id_config)
    .eq("fecha", fecha)
    .eq("hora_envio", config.hora_envio)
    .maybeSingle();

  if (buscarError) {
    throw new Error(`No se pudo buscar log existente: ${buscarError.message}`);
  }

  if (existente?.id_log) {
    const { error: updateError } = await supabase
      .from("alerta_puntualidad_log")
      .update(payload)
      .eq("id_log", existente.id_log);
    if (updateError) {
      throw new Error(`No se pudo actualizar log: ${updateError.message}`);
    }
    return;
  }

  const { error: insertError } = await supabase
    .from("alerta_puntualidad_log")
    .insert(payload);
  if (insertError) {
    throw new Error(`No se pudo insertar log: ${insertError.message}`);
  }
}

function renderHtml(params: {
  tituloReporte: string;
  config: Configuracion;
  fecha: string;
  secciones: SeccionTienda[];
  incluirTracking: boolean;
}) {
  const { tituloReporte, config, fecha, secciones, incluirTracking } = params;
  const totalPendientes = secciones.reduce(
    (total, item) => total + item.pendientes.length,
    0,
  );
  const contenido = secciones.map((seccion) =>
    seccionHtml(seccion, incluirTracking)
  ).join("");

  return `<!doctype html>
<html lang="es">
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      .mobile-only {
        display: none;
        max-height: 0;
        overflow: hidden;
        mso-hide: all;
      }
      @media only screen and (max-width: 620px) {
        body { padding: 0 !important; }
        .contenedor {
          width: 100% !important;
          max-width: 100% !important;
          padding: 16px 12px !important;
          border-radius: 0 !important;
          box-shadow: none !important;
        }
        .titulo-principal { font-size: 22px !important; line-height: 1.25 !important; }
        .seccion-contenido { padding: 14px 10px !important; }
        .desktop-only {
          display: none !important;
          max-height: 0 !important;
          overflow: hidden !important;
          mso-hide: all !important;
        }
        .mobile-only {
          display: block !important;
          max-height: none !important;
          overflow: visible !important;
        }
      }
    </style>
  </head>
  <body style="font-family:Arial,Helvetica,sans-serif;color:#17202a;margin:0;background:#f4f6f8;padding:20px 8px;">
    <div class="contenedor" style="box-sizing:border-box;max-width:980px;margin:0 auto;background:#fff;border-radius:12px;padding:26px;box-shadow:0 2px 8px rgba(0,0,0,.08);">
      <h1 class="titulo-principal" style="font-size:23px;line-height:1.25;margin:0 0 8px;color:#153e75;">Alertas de puntualidad - ${
    escapeHtml(tituloReporte)
  }</h1>
      <p style="margin:0 0 4px;color:#52606d;">Fecha: ${
    escapeHtml(fechaLarga(fecha))
  }</p>
      <p style="margin:0 0 20px;color:#52606d;">Reporte: ${
    escapeHtml(config.nombre_reporte)
  } · ${escapeHtml(config.hora_envio.slice(0, 5))}</p>
      <div style="background:#ebf8ff;border-left:4px solid #3182ce;padding:12px 14px;margin-bottom:22px;">
        Pendientes de asistencia: <strong>${totalPendientes}</strong>
        ${
    incluirTracking
      ? "<br>Este es el ultimo reporte configurado del area; incluye el tracking del dia."
      : ""
  }
      </div>
      ${contenido}
      ${
    incluirTracking
      ? `<p style="font-size:12px;color:#718096;margin:22px 0 0;">Las marcas de tracking libre no guardan un tipo explicito. “Llegada/Salida” se presenta segun el orden cronologico de las marcas realizadas por trabajador y lugar.</p>`
      : ""
  }
    </div>
  </body>
</html>`;
}

function seccionHtml(seccion: SeccionTienda, incluirTracking: boolean) {
  const filasAsistencia = seccion.pendientes.length === 0
    ? `<tr><td colspan="7" style="${tdStyle}">Sin alertas pendientes.</td></tr>`
    : seccion.pendientes.map(filaAsistenciaHtml).join("");
  const tarjetasAsistencia = seccion.pendientes.length === 0
    ? `<p style="margin:0;color:#718096;">Sin alertas pendientes.</p>`
    : seccion.pendientes.map(tarjetaAsistenciaHtml).join("");
  const tracking = incluirTracking && seccion.tracking.length > 0
    ? trackingHtml(seccion.tracking)
    : incluirTracking
    ? `<p style="margin:8px 0 0;color:#718096;">Sin tracking registrado para trabajadores asignados a esta tienda.</p>`
    : "";

  return `<section style="border:1px solid #d9e2ec;border-radius:10px;margin:0 0 22px;overflow:hidden;">
    <h2 style="font-size:19px;margin:0;padding:14px 16px;background:#153e75;color:#fff;">Tienda: ${
    escapeHtml(seccion.tienda.nombre)
  }</h2>
    <div class="seccion-contenido" style="padding:16px;">
      <h3 style="font-size:16px;margin:0 0 10px;">Asistencia</h3>
      <div class="desktop-only" style="display:block;overflow-x:auto;">
        <table class="tabla" style="border-collapse:collapse;width:100%;min-width:760px;font-size:13px;">
          <thead><tr>
            <th style="${thStyle}">Trabajador</th>
            <th style="${thStyle}">DNI</th>
            <th style="${thStyle}">Telefono</th>
            <th style="${thStyle}">Cargo</th>
            <th style="${thStyle}">Entrada esperada</th>
            <th style="${thStyle}">Entrada real</th>
            <th style="${thStyle}">Motivo</th>
          </tr></thead>
          <tbody>${filasAsistencia}</tbody>
        </table>
      </div>
      <div class="mobile-only" style="display:none;max-height:0;overflow:hidden;mso-hide:all;">
        ${tarjetasAsistencia}
      </div>
      ${
    incluirTracking
      ? `<h3 style="font-size:16px;margin:22px 0 10px;">Tracking del dia</h3>${tracking}`
      : ""
  }
    </div>
  </section>`;
}

function filaAsistenciaHtml(item: TrabajadorPendiente) {
  return `<tr>
    <td style="${tdStyle}">${escapeHtml(item.nombre_trabajador)}</td>
    <td style="${tdStyle}">${escapeHtml(item.dni_trabajador)}</td>
    <td style="${tdStyle}">${escapeHtml(item.telefono)}</td>
    <td style="${tdStyle}">${escapeHtml(item.cargo)}</td>
    <td style="${tdStyle}">${escapeHtml(item.hora_programada)}</td>
    <td style="${tdStyle}">${escapeHtml(item.hora_marcada ?? "Sin marca")}</td>
    <td style="${tdStyle}">${escapeHtml(item.motivo)}</td>
  </tr>`;
}

function tarjetaAsistenciaHtml(item: TrabajadorPendiente) {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="width:100%;border:1px solid #cbd5e0;border-radius:8px;border-collapse:separate;margin:0 0 12px;background:#fff;">
    <tr>
      <td colspan="2" style="padding:12px;background:#edf2f7;border-radius:8px 8px 0 0;font-weight:700;line-height:1.35;word-break:break-word;">
        ${escapeHtml(item.nombre_trabajador)}
      </td>
    </tr>
    ${filaDatoMovil("DNI", item.dni_trabajador)}
    ${filaDatoMovil("Telefono", item.telefono || "No registrado")}
    ${filaDatoMovil("Cargo", item.cargo || "No registrado")}
    ${filaDatoMovil("Entrada esperada", item.hora_programada)}
    ${filaDatoMovil("Entrada real", item.hora_marcada ?? "Sin marca")}
    ${filaDatoMovil("Motivo", item.motivo, true)}
  </table>`;
}

function trackingHtml(items: TrackingDetalle[]) {
  const filas = items.map((item) =>
    `<tr>
    <td style="${tdStyle}">${escapeHtml(item.nombre_trabajador)}</td>
    <td style="${tdStyle}">${escapeHtml(item.dni_trabajador)}</td>
    <td style="${tdStyle}">${escapeHtml(item.lugar)}</td>
    <td style="${tdStyle}">${escapeHtml(item.evento)}</td>
    <td style="${tdStyle}">${escapeHtml(item.hora)}</td>
    <td style="${tdStyle}">${escapeHtml(item.direccion)}</td>
    <td style="${tdStyle}">${
      item.enlace_mapa
        ? `<a href="${
          escapeHtml(item.enlace_mapa)
        }" style="color:#2b6cb0;">Ver ubicacion</a>`
        : "Sin coordenadas"
    }</td>
  </tr>`
  ).join("");
  const tarjetas = items.map(tarjetaTrackingHtml).join("");
  return `<div class="desktop-only" style="display:block;overflow-x:auto;">
    <table class="tabla" style="border-collapse:collapse;width:100%;min-width:820px;font-size:13px;">
      <thead><tr>
        <th style="${thStyle}">Trabajador</th>
        <th style="${thStyle}">DNI</th>
        <th style="${thStyle}">Lugar visitado</th>
        <th style="${thStyle}">Movimiento</th>
        <th style="${thStyle}">Hora</th>
        <th style="${thStyle}">Direccion</th>
        <th style="${thStyle}">Mapa</th>
      </tr></thead>
      <tbody>${filas}</tbody>
    </table>
  </div>
  <div class="mobile-only" style="display:none;max-height:0;overflow:hidden;mso-hide:all;">
    ${tarjetas}
  </div>`;
}

function tarjetaTrackingHtml(item: TrackingDetalle) {
  const mapa = item.enlace_mapa
    ? `<a href="${
      escapeHtml(item.enlace_mapa)
    }" style="color:#2b6cb0;text-decoration:underline;">Ver ubicacion en Maps</a>`
    : "Sin coordenadas";
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="width:100%;border:1px solid #cbd5e0;border-radius:8px;border-collapse:separate;margin:0 0 12px;background:#fff;">
    <tr>
      <td colspan="2" style="padding:12px;background:#edf2f7;border-radius:8px 8px 0 0;font-weight:700;line-height:1.35;word-break:break-word;">
        ${escapeHtml(item.nombre_trabajador)}
      </td>
    </tr>
    ${filaDatoMovil("DNI", item.dni_trabajador)}
    ${filaDatoMovil("Lugar visitado", item.lugar)}
    ${filaDatoMovil("Movimiento", item.evento)}
    ${filaDatoMovil("Hora", item.hora)}
    ${filaDatoMovil("Direccion", item.direccion)}
    ${filaDatoMovil("Mapa", mapa, true, true)}
  </table>`;
}

function filaDatoMovil(
  etiqueta: string,
  valor: string,
  ultima = false,
  valorHtml = false,
) {
  const borde = ultima ? "" : "border-bottom:1px solid #e2e8f0;";
  return `<tr>
    <td valign="top" style="${borde}width:38%;padding:9px 8px;font-size:12px;line-height:1.35;color:#52606d;font-weight:700;word-break:break-word;">
      ${escapeHtml(etiqueta)}
    </td>
    <td valign="top" style="${borde}padding:9px 8px;font-size:13px;line-height:1.4;color:#17202a;word-break:break-word;">
      ${valorHtml ? valor : escapeHtml(valor)}
    </td>
  </tr>`;
}

function renderTexto(params: {
  tituloReporte: string;
  config: Configuracion;
  fecha: string;
  secciones: SeccionTienda[];
  incluirTracking: boolean;
}) {
  const { tituloReporte, config, fecha, secciones, incluirTracking } = params;
  const lineas = [
    `Alertas de puntualidad - ${tituloReporte}`,
    `Fecha: ${fechaLarga(fecha)}`,
    `Reporte: ${config.nombre_reporte} - ${config.hora_envio.slice(0, 5)}`,
    "",
  ];
  for (const seccion of secciones) {
    lineas.push(
      `TIENDA: ${seccion.tienda.nombre}`,
      `ASISTENCIA (${seccion.pendientes.length} pendientes)`,
      ...(seccion.pendientes.length === 0
        ? ["Sin alertas pendientes."]
        : seccion.pendientes.map((item) =>
          `${item.nombre_trabajador} | DNI ${item.dni_trabajador} | Esperada ${item.hora_programada} | Real ${
            item.hora_marcada ?? "Sin marca"
          } | ${item.motivo}`
        )),
    );
    if (incluirTracking) {
      lineas.push(
        "TRACKING DEL DIA",
        ...(seccion.tracking.length === 0
          ? ["Sin tracking registrado."]
          : seccion.tracking.map((item) =>
            `${item.nombre_trabajador} | ${item.lugar} | ${item.evento} ${item.hora} | ${item.direccion}${
              item.enlace_mapa ? ` | ${item.enlace_mapa}` : ""
            }`
          )),
      );
    }
    lineas.push("");
  }
  return lineas.join("\n");
}

const thStyle =
  "border:1px solid #222;padding:10px;font-weight:700;text-align:center;background:#fafafa";
const tdStyle = "border:1px solid #222;padding:10px;text-align:left";

async function readBody(req: Request): Promise<RequestBody> {
  const raw = await req.text();
  if (!raw.trim()) {
    return {};
  }
  return JSON.parse(raw) as RequestBody;
}

function requiredEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Falta secret ${name}.`);
  }
  return value;
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function fechaLima() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: zonaHoraria,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  return `${part(parts, "year")}-${part(parts, "month")}-${part(parts, "day")}`;
}

function horaLimaActual() {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: zonaHoraria,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date());
  return `${part(parts, "hour")}:${part(parts, "minute")}:${
    part(parts, "second")
  }`;
}

function fechaLarga(fecha: string) {
  const [year, month, day] = fecha.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day, 12));
  const dia = new Intl.DateTimeFormat("es-PE", {
    timeZone: "UTC",
    weekday: "long",
  }).format(date);
  return `${fecha} (${dia})`;
}

function diaSemanaLima(fecha: string) {
  const [year, month, day] = fecha.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day, 12));
  const dia = new Intl.DateTimeFormat("es-PE", {
    timeZone: "UTC",
    weekday: "long",
  }).format(date).toLowerCase();
  return dia.normalize("NFD").replace(/\p{Diacritic}/gu, "");
}

function horaLima(value: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: zonaHoraria,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(new Date(value));
  return `${part(parts, "hour")}:${part(parts, "minute")}`;
}

function minutosDesdeFechaLima(value: string) {
  const [hour, minute] = horaLima(value).split(":").map(Number);
  return hour * 60 + minute;
}

function minutosDesdeHora(value: string) {
  const [hour, minute] = normalizarHora(value).split(":").map(Number);
  return hour * 60 + minute;
}

function normalizarHora(value: string) {
  const match = value.trim().match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?/);
  if (!match) {
    return "00:00:00";
  }
  return `${match[1].padStart(2, "0")}:${match[2]}:${match[3] ?? "00"}`;
}

function normalizarCorreo(value: string | null | undefined) {
  return value?.trim().toLowerCase() ?? "";
}

function part(parts: Intl.DateTimeFormatPart[], type: string) {
  return parts.find((item) => item.type === type)?.value ?? "";
}

function escapeHtml(value: string | number | null | undefined) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
