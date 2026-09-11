import "jsr:@supabase/functions-js/edge-runtime.d.ts";

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
};

type Horario = {
  dni_trabajador: string;
  dia_semana: string;
  horario_entrada: string | null;
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
const cronSecret = Deno.env.get("CRON_SECRET")?.trim() ?? "";

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

    if (cronSecret) {
      const recibido = req.headers.get("x-cron-secret")?.trim() ?? "";
      if (recibido !== cronSecret) {
        return json({ ok: false, error: "No autorizado." }, 401);
      }
    }

    const body = await readBody(req);
    const fecha = body.fecha ?? fechaLima();
    const horaEnvio = normalizarHora(
      body.hora_envio ?? horaProgramadaDesdeAhora(),
    );
    const enviarVacios = body.enviar_vacios ?? true;

    const configs = await obtenerConfiguraciones(body, horaEnvio);
    const resultados = [];

    for (const config of configs) {
      const resultado = await procesarConfiguracion({
        config,
        fecha,
        horaEnvio,
        correoOverride: body.correo_prueba,
        enviarVacios,
      });
      resultados.push(resultado);
    }

    return json({
      ok: true,
      fecha,
      hora_envio: horaEnvio,
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

async function obtenerConfiguraciones(body: RequestBody, horaEnvio: string) {
  const correoFiltro = normalizarCorreo(
    body.correo_destino ?? body.correo_prueba,
  );
  const data = await consultarConfiguraciones({
    horaEnvio,
    idConfig: body.id_config,
    tipoReporte: body.tipo_reporte,
    idTienda: body.id_tienda,
    correoDestino: body.correo_destino,
  });

  if (data.length > 0 || !body.id_tienda || body.id_config || !correoFiltro) {
    return data;
  }

  // Fallback para pruebas: si la tienda cambio, busca la config actual por correo.
  return await consultarConfiguraciones({
    horaEnvio,
    tipoReporte: body.tipo_reporte,
    correoDestino: correoFiltro,
  });
}

async function consultarConfiguraciones(params: {
  horaEnvio: string;
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
    .eq("activo", true)
    .eq("hora_envio", params.horaEnvio);

  if (params.idConfig) {
    query = query.eq("id_config", params.idConfig);
  }
  if (params.tipoReporte) {
    query = query.eq("tipo_reporte", params.tipoReporte);
  }
  if (params.idTienda) {
    query = query.eq("id_tienda", params.idTienda);
  }

  const { data, error } = await query.order("tipo_reporte", {
    ascending: true,
  });
  if (error) {
    throw new Error(`No se pudo leer alerta_puntualidad_config: ${error.message}`);
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

async function procesarConfiguracion(params: {
  config: Configuracion;
  fecha: string;
  horaEnvio: string;
  correoOverride?: string;
  enviarVacios: boolean;
}) {
  const { config, fecha, horaEnvio, correoOverride, enviarVacios } = params;
  const destino = correoOverride?.trim() || config.correo_destino;
  const tienda = config.id_tienda ? await obtenerTienda(config.id_tienda) : null;
  const trabajadores = await obtenerTrabajadores(config);
  const pendientes = await calcularPendientes({
    trabajadores,
    fecha,
    tolerancia: config.minutos_tolerancia,
    horaEnvio,
  });
  const tituloReporte = config.tipo_reporte === "GENERAL"
    ? "GENERAL"
    : tienda?.nombre ?? "Tienda";
  const html = renderHtml({
    tituloReporte,
    config,
    fecha,
    pendientes,
  });
  const text = renderTexto({
    tituloReporte,
    config,
    fecha,
    pendientes,
  });

  let enviado = false;
  let error: string | null = null;

  if (pendientes.length > 0 || enviarVacios) {
    try {
      await transporter.sendMail({
        from: `"${gmailFromName}" <${gmailUser}>`,
        to: destino,
        subject: `Alertas de puntualidad - ${tituloReporte} - ${config.nombre_reporte}`,
        html,
        text,
      });
      enviado = true;
    } catch (sendError) {
      error = sendError instanceof Error ? sendError.message : String(sendError);
      console.error("Error enviando correo", {
        id_config: config.id_config,
        destino,
        error,
      });
    }
  }

  await guardarLog({
    config,
    fecha,
    destino,
    pendientes,
    enviado,
    error,
  });

  return {
    id_config: config.id_config,
    tipo_reporte: config.tipo_reporte,
    id_tienda: config.id_tienda,
    correo_destino: destino,
    total_trabajadores: pendientes.length,
    enviado,
    error,
  };
}

async function obtenerTienda(idTienda: string): Promise<Tienda | null> {
  const { data, error } = await supabase
    .from("tienda")
    .select("id_tienda,nombre,estado")
    .eq("id_tienda", idTienda)
    .maybeSingle();
  if (error) {
    throw new Error(`No se pudo leer tienda ${idTienda}: ${error.message}`);
  }
  return data as Tienda | null;
}

async function obtenerTrabajadores(config: Configuracion) {
  let query = supabase
    .from("trabajador")
    .select("dni,id_tienda,nombre,cargo,telefono,estado")
    .eq("estado", true);

  if (config.tipo_reporte === "TIENDA") {
    if (!config.id_tienda) {
      return [];
    }
    query = query.eq("id_tienda", config.id_tienda);
  }

  const { data, error } = await query.order("nombre", { ascending: true });
  if (error) {
    throw new Error(`No se pudo leer trabajador: ${error.message}`);
  }

  return (data ?? []) as Trabajador[];
}

async function calcularPendientes(params: {
  trabajadores: Trabajador[];
  fecha: string;
  tolerancia: number;
  horaEnvio: string;
}): Promise<TrabajadorPendiente[]> {
  const { trabajadores, fecha, tolerancia, horaEnvio } = params;
  if (trabajadores.length === 0) {
    return [];
  }

  const dnis = trabajadores.map((item) => item.dni);
  const tiendasIds = [
    ...new Set(
      trabajadores
        .map((item) => item.id_tienda)
        .filter((value): value is string => Boolean(value)),
    ),
  ];
  const diaSemana = diaSemanaLima(fecha);
  const [asistencias, horarios, tiendas] = await Promise.all([
    obtenerAsistencias(dnis, fecha),
    obtenerHorarios(dnis, diaSemana),
    obtenerTiendas(tiendasIds),
  ]);

  const asistenciaPorDni = new Map(
    asistencias.map((item) => [item.dni_trabajador, item]),
  );
  const horarioPorDni = new Map(
    horarios.map((item) => [item.dni_trabajador, item]),
  );
  const tiendaPorId = new Map(tiendas.map((item) => [item.id_tienda, item]));
  const horaReporteMinutos = minutosDesdeHora(horaEnvio);
  const inicioVentanaMinutos = inicioVentanaReporte(horaEnvio);
  const pendientes: TrabajadorPendiente[] = [];

  for (const trabajador of trabajadores) {
    const horario = horarioPorDni.get(trabajador.dni);
    if (!horario?.horario_entrada) {
      continue;
    }

    const asistencia = asistenciaPorDni.get(trabajador.dni);
    const horaProgramada = normalizarHora(horario.horario_entrada);
    const horaProgramadaMinutos = minutosDesdeHora(horaProgramada);
    if (
      horaProgramadaMinutos < inicioVentanaMinutos ||
      horaProgramadaMinutos + tolerancia > horaReporteMinutos
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
      nombre_tienda: tiendaPorId.get(idTienda)?.nombre ?? "Tienda",
      tipo_marcacion: "Entrada",
      hora_programada: horaProgramada.slice(0, 5),
      hora_marcada: horaMarcada,
      minutos_tarde: minutosTarde,
      motivo,
    });
  }

  return pendientes;
}

async function obtenerAsistencias(dnis: string[], fecha: string) {
  const { data, error } = await supabase
    .from("asistencia")
    .select("dni_trabajador,fecha,horario_entrada")
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

async function obtenerTiendas(ids: string[]) {
  if (ids.length === 0) {
    return [];
  }

  const { data, error } = await supabase
    .from("tienda")
    .select("id_tienda,nombre,estado")
    .in("id_tienda", ids);
  if (error) {
    throw new Error(`No se pudo leer tienda: ${error.message}`);
  }
  return (data ?? []) as Tienda[];
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
  pendientes: TrabajadorPendiente[];
}) {
  const { tituloReporte, config, fecha, pendientes } = params;
  const mostrarTienda = config.tipo_reporte === "GENERAL";
  const filas = pendientes.length === 0
    ? `<tr><td colspan="${mostrarTienda ? 8 : 7}">Sin pendientes.</td></tr>`
    : pendientes.map((item) => filaHtml(item, mostrarTienda)).join("");

  return `<!doctype html>
<html>
  <body style="font-family: Arial, Helvetica, sans-serif; color: #222; margin: 0; padding: 0;">
    <h2 style="font-size: 22px; margin: 0 0 26px;">Alertas de puntualidad - ${escapeHtml(tituloReporte)}</h2>
    <p style="margin: 0 0 4px;">Fecha: ${escapeHtml(fechaLarga(fecha))}</p>
    <p style="margin: 0 0 22px;">Reporte: ${escapeHtml(config.nombre_reporte)} - ${escapeHtml(config.hora_envio.slice(0, 5))}</p>
    <p style="margin: 0 0 18px;">Total pendientes: <strong>${pendientes.length}</strong></p>
    <table style="border-collapse: collapse; width: 100%; font-size: 14px;">
      <thead>
        <tr>
          <th style="${thStyle}">Trabajador</th>
          <th style="${thStyle}">DNI</th>
          <th style="${thStyle}">Telefono</th>
          <th style="${thStyle}">Cargo</th>
          ${mostrarTienda ? `<th style="${thStyle}">Tienda</th>` : ""}
          <th style="${thStyle}">Entrada esperada</th>
          <th style="${thStyle}">Entrada real</th>
          <th style="${thStyle}">Motivo</th>
        </tr>
      </thead>
      <tbody>${filas}</tbody>
    </table>
  </body>
</html>`;
}

function filaHtml(item: TrabajadorPendiente, mostrarTienda: boolean) {
  return `<tr>
    <td style="${tdStyle}">${escapeHtml(item.nombre_trabajador)}</td>
    <td style="${tdStyle}">${escapeHtml(item.dni_trabajador)}</td>
    <td style="${tdStyle}">${escapeHtml(item.telefono)}</td>
    <td style="${tdStyle}">${escapeHtml(item.cargo)}</td>
    ${mostrarTienda ? `<td style="${tdStyle}">${escapeHtml(item.nombre_tienda)}</td>` : ""}
    <td style="${tdStyle}">${escapeHtml(item.hora_programada)}</td>
    <td style="${tdStyle}">${escapeHtml(item.hora_marcada ?? "Sin marca")}</td>
    <td style="${tdStyle}">${escapeHtml(item.motivo)}</td>
  </tr>`;
}

function renderTexto(params: {
  tituloReporte: string;
  config: Configuracion;
  fecha: string;
  pendientes: TrabajadorPendiente[];
}) {
  const { tituloReporte, config, fecha, pendientes } = params;
  return [
    `Alertas de puntualidad - ${tituloReporte}`,
    `Fecha: ${fechaLarga(fecha)}`,
    `Reporte: ${config.nombre_reporte} - ${config.hora_envio.slice(0, 5)}`,
    `Total pendientes: ${pendientes.length}`,
    "",
    ...pendientes.map((item) =>
      `${item.nombre_trabajador} | DNI ${item.dni_trabajador} | ${item.nombre_tienda} | Esperada ${item.hora_programada} | Real ${item.hora_marcada ?? "Sin marca"} | ${item.motivo}`
    ),
  ].join("\n");
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

function horaProgramadaDesdeAhora() {
  const hora = Number(
    new Intl.DateTimeFormat("en-US", {
      timeZone: zonaHoraria,
      hour: "2-digit",
      hour12: false,
    }).format(new Date()),
  );
  return hora < 12 ? "08:30:00" : "13:30:00";
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

function inicioVentanaReporte(horaEnvio: string) {
  const horaReporteMinutos = minutosDesdeHora(horaEnvio);
  return horaReporteMinutos >= 12 * 60 ? 12 * 60 : 0;
}

function normalizarHora(value: string) {
  const match = value.trim().match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?/);
  if (!match) {
    return "08:30:00";
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
