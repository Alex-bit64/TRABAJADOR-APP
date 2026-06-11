import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

type Trabajador = {
  dni: string;
  nombre: string | null;
  cargo: string | null;
  id_tienda: string;
};

type Horario = {
  dni_trabajador: string;
  horario_entrada: string | null;
};

type Asistencia = {
  dni_trabajador: string;
  horario_entrada: string | null;
  justificado: boolean | null;
};

type Alerta = {
  dni: string;
  nombre: string;
  cargo: string;
  id_tienda: string;
  fecha: string;
  tipo_marcacion: string;
  motivo: string;
  entradaEsperada: string;
  entradaReal: string;
  minutosTarde: number | null;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? "";
const alertFrom = Deno.env.get("ALERT_FROM") ?? "Marcador <onboarding@resend.dev>";
const alertTestTo = Deno.env.get("ALERT_TEST_TO") ?? "";

const supabase = createClient(supabaseUrl, serviceRoleKey);

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Metodo no permitido" }, 405);
  }

  if (!supabaseUrl || !serviceRoleKey || !resendApiKey) {
    return json(
      {
        error:
          "Faltan secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY o RESEND_API_KEY.",
      },
      500,
    );
  }

  const body = await readJson(req);
  const tiendaFiltro = normalizeText(body?.tienda?.toString() ?? "CONTABILIDAD");
  const soloNoMarcados = body?.solo_no_marcados === true;
  const now = new Date();
  const fecha = limaDate(now);
  const diaSemana = limaWeekday(now);
  const nowMinutes = limaMinutes(now);

  const { data: tienda, error: tiendaError } = await supabase
    .from("tienda")
    .select("id_tienda,nombre")
    .ilike("nombre", `%${tiendaFiltro}%`)
    .limit(1)
    .maybeSingle();

  if (tiendaError) {
    return json({ error: tiendaError.message }, 500);
  }

  if (!tienda) {
    return json({
      ok: true,
      mensaje: `No se encontro tienda para ${tiendaFiltro}.`,
      enviados: 0,
    });
  }

  const { data: configs, error: configError } = await supabase
    .from("alerta_puntualidad_config")
    .select(
      "id_config,id_tienda,correo_destino,minutos_tolerancia,activo,enviar_resumen",
    )
    .eq("id_tienda", tienda.id_tienda)
    .eq("activo", true);

  if (configError) {
    return json({ error: configError.message }, 500);
  }

  if (!configs || configs.length === 0) {
    return json({
      ok: true,
      mensaje: `La tienda ${tienda.nombre} no tiene configuracion activa.`,
      enviados: 0,
    });
  }

  if (body?.modo_prueba === true) {
    const correoDestino = destinoSeguro(configs[0].correo_destino);
    const emailResult = await enviarResumen({
      to: correoDestino,
      tienda: tienda.nombre,
      fecha,
      diaSemana,
      alertas: [{
        dni: "00000000",
        nombre: "Correo de prueba",
        cargo: "Sistema",
        id_tienda: tienda.id_tienda,
        fecha,
        tipo_marcacion: "prueba",
        motivo: "Prueba de envio desde Supabase Edge Functions y Resend.",
        entradaEsperada: "Sin dato",
        entradaReal: "Sin dato",
        minutosTarde: null,
      }],
    });

    return json({
      ok: emailResult.ok,
      modo_prueba: true,
      correo_destino: correoDestino,
      error: emailResult.error,
    }, emailResult.ok ? 200 : 500);
  }

  const { data: trabajadores, error: trabajadoresError } = await supabase
    .from("trabajador")
    .select("dni,nombre,cargo,id_tienda")
    .eq("id_tienda", tienda.id_tienda)
    .eq("estado", true);

  if (trabajadoresError) {
    return json({ error: trabajadoresError.message }, 500);
  }

  const trabajadoresList = (trabajadores ?? []) as Trabajador[];
  if (trabajadoresList.length === 0) {
    return json({
      ok: true,
      mensaje: `La tienda ${tienda.nombre} no tiene trabajadores activos.`,
      enviados: 0,
    });
  }

  const dnis = trabajadoresList.map((item) => item.dni);
  const { data: horarios, error: horariosError } = await supabase
    .from("horario_trabajador")
    .select("dni_trabajador,horario_entrada")
    .in("dni_trabajador", dnis)
    .eq("dia_semana", diaSemana);

  if (horariosError) {
    return json({ error: horariosError.message }, 500);
  }

  const horariosByDni = new Map(
    ((horarios ?? []) as Horario[]).map((item) => [item.dni_trabajador, item]),
  );
  const trabajadoresConHorario = trabajadoresList.filter((trabajador) =>
    horariosByDni.has(trabajador.dni)
  );

  if (trabajadoresConHorario.length === 0) {
    return json({
      ok: true,
      mensaje:
        `No hay trabajadores con horario para ${diaSemana} en ${tienda.nombre}.`,
      enviados: 0,
    });
  }

  const { data: asistencias, error: asistenciaError } = await supabase
    .from("asistencia")
    .select("dni_trabajador,horario_entrada,justificado")
    .in("dni_trabajador", trabajadoresConHorario.map((item) => item.dni))
    .eq("fecha", fecha);

  if (asistenciaError) {
    return json({ error: asistenciaError.message }, 500);
  }

  const asistenciasByDni = new Map(
    ((asistencias ?? []) as Asistencia[]).map((item) => [
      item.dni_trabajador,
      item,
    ]),
  );

  const alertas = detectarAlertas({
    trabajadores: trabajadoresConHorario,
    horariosByDni,
    asistenciasByDni,
    fecha,
    nowMinutes,
    toleranciaDefault: configs[0].minutos_tolerancia ?? 10,
    soloNoMarcados,
  });

  if (alertas.length === 0) {
    return json({
      ok: true,
      mensaje: soloNoMarcados
        ? `Sin trabajadores pendientes de marcar entrada para ${tienda.nombre}.`
        : `Sin tardanzas detectadas para ${tienda.nombre}.`,
      enviados: 0,
    });
  }

  const resultados = [];
  for (const config of configs) {
    const correoDestino = destinoSeguro(config.correo_destino);
    const nuevas = await filtrarAlertasNuevas(
      alertas,
      config.id_config,
      correoDestino,
    );

    if (nuevas.length === 0) {
      resultados.push({
        correo_destino: correoDestino,
        enviados: 0,
        mensaje: "Sin alertas nuevas.",
      });
      continue;
    }

    const logs = nuevas.map((alerta) => ({
      id_config: config.id_config,
      id_tienda: alerta.id_tienda,
      dni_trabajador: alerta.dni,
      fecha: alerta.fecha,
      tipo_marcacion: alerta.tipo_marcacion,
      correo_destino: correoDestino,
      motivo: alerta.motivo,
      enviado: false,
    }));

    const { error: insertError } = await supabase
      .from("alerta_puntualidad_log")
      .insert(logs);

    if (insertError) {
      resultados.push({
        correo_destino: correoDestino,
        enviados: 0,
        error: insertError.message,
      });
      continue;
    }

    const emailResult = await enviarResumen({
      to: correoDestino,
      tienda: tienda.nombre,
      fecha,
      diaSemana,
      alertas: nuevas,
    });

    await actualizarLogs(nuevas, correoDestino, emailResult.ok, emailResult.error);
    resultados.push({
      correo_destino: correoDestino,
      enviados: emailResult.ok ? nuevas.length : 0,
      error: emailResult.error,
    });
  }

  return json({
    ok: true,
    tienda: tienda.nombre,
    fecha,
    diaSemana,
    solo_no_marcados: soloNoMarcados,
    alertas_detectadas: alertas.length,
    resultados,
  });
});

function detectarAlertas(params: {
  trabajadores: Trabajador[];
  horariosByDni: Map<string, Horario>;
  asistenciasByDni: Map<string, Asistencia>;
  fecha: string;
  nowMinutes: number;
  toleranciaDefault: number;
  soloNoMarcados: boolean;
}): Alerta[] {
  const alertas: Alerta[] = [];

  for (const trabajador of params.trabajadores) {
    const horario = params.horariosByDni.get(trabajador.dni);
    if (!horario?.horario_entrada) {
      continue;
    }

    const asistencia = params.asistenciasByDni.get(trabajador.dni);
    if (asistencia?.justificado === false) {
      continue;
    }

    const esperada = timeToMinutes(horario.horario_entrada);
    if (esperada == null) {
      continue;
    }

    const limite = esperada + params.toleranciaDefault;
    const real = asistencia?.horario_entrada
      ? timestampToLimaMinutes(asistencia.horario_entrada)
      : null;

    if (real != null) {
      if (params.soloNoMarcados) {
        continue;
      }

      const minutosTarde = real - esperada;
      if (minutosTarde > params.toleranciaDefault) {
        alertas.push({
          dni: trabajador.dni,
          nombre: trabajador.nombre ?? "Sin nombre",
          cargo: trabajador.cargo ?? "",
          id_tienda: trabajador.id_tienda,
          fecha: params.fecha,
          tipo_marcacion: "entrada_tarde",
          motivo: `Entrada tarde por ${minutosTarde} minutos.`,
          entradaEsperada: minutesToTime(esperada),
          entradaReal: minutesToTime(real),
          minutosTarde,
        });
      }
      continue;
    }

    if (params.nowMinutes > limite) {
      alertas.push({
        dni: trabajador.dni,
        nombre: trabajador.nombre ?? "Sin nombre",
        cargo: trabajador.cargo ?? "",
        id_tienda: trabajador.id_tienda,
        fecha: params.fecha,
        tipo_marcacion: "entrada_no_marcada",
        motivo: "No marco entrada dentro de la tolerancia.",
        entradaEsperada: minutesToTime(esperada),
        entradaReal: "Sin marca",
        minutosTarde: null,
      });
    }
  }

  return alertas;
}

async function filtrarAlertasNuevas(
  alertas: Alerta[],
  idConfig: string,
  correoDestino: string,
) {
  const { data, error } = await supabase
    .from("alerta_puntualidad_log")
    .select("dni_trabajador,tipo_marcacion")
    .eq("id_config", idConfig)
    .eq("fecha", alertas[0].fecha)
    .eq("correo_destino", correoDestino)
    .in("dni_trabajador", alertas.map((item) => item.dni));

  if (error) {
    throw error;
  }

  const existentes = new Set(
    (data ?? []).map((item) =>
      `${item.dni_trabajador}:${item.tipo_marcacion}`
    ),
  );

  return alertas.filter(
    (item) => !existentes.has(`${item.dni}:${item.tipo_marcacion}`),
  );
}

async function enviarResumen(params: {
  to: string;
  tienda: string;
  fecha: string;
  diaSemana: string;
  alertas: Alerta[];
}) {
  const rows = params.alertas
    .map((alerta) =>
      `<tr>
        <td>${escapeHtml(alerta.nombre)}</td>
        <td>${escapeHtml(alerta.dni)}</td>
        <td>${escapeHtml(alerta.cargo)}</td>
        <td>${alerta.entradaEsperada}</td>
        <td>${alerta.entradaReal}</td>
        <td>${escapeHtml(alerta.motivo)}</td>
      </tr>`
    )
    .join("");

  const html = `
    <h2>Alertas de puntualidad - ${escapeHtml(params.tienda)}</h2>
    <p>Fecha: ${params.fecha} (${params.diaSemana})</p>
    <table border="1" cellpadding="8" cellspacing="0">
      <thead>
        <tr>
          <th>Trabajador</th>
          <th>DNI</th>
          <th>Cargo</th>
          <th>Entrada esperada</th>
          <th>Entrada real</th>
          <th>Motivo</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  `;

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: alertFrom,
      to: [params.to],
      subject: `Alertas de puntualidad - ${params.tienda} - ${params.fecha}`,
      html,
    }),
  });

  if (response.ok) {
    return { ok: true };
  }

  return { ok: false, error: await response.text() };
}

async function actualizarLogs(
  alertas: Alerta[],
  correoDestino: string,
  enviado: boolean,
  error?: string,
) {
  for (const alerta of alertas) {
    await supabase
      .from("alerta_puntualidad_log")
      .update({ enviado, error: error ?? null })
      .eq("id_tienda", alerta.id_tienda)
      .eq("dni_trabajador", alerta.dni)
      .eq("fecha", alerta.fecha)
      .eq("tipo_marcacion", alerta.tipo_marcacion)
      .eq("correo_destino", correoDestino);
  }
}

function destinoSeguro(correoConfig: string) {
  if (alertFrom.includes("onboarding@resend.dev") && alertTestTo) {
    return alertTestTo;
  }
  return correoConfig;
}

function limaDate(date: Date) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Lima",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function limaWeekday(date: Date) {
  const weekday = new Intl.DateTimeFormat("es-PE", {
    timeZone: "America/Lima",
    weekday: "long",
  }).format(date);
  return normalizeText(weekday);
}

function limaMinutes(date: Date) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Lima",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return Number(values.hour) * 60 + Number(values.minute);
}

function timestampToLimaMinutes(value: string) {
  const date = new Date(value.replace(" ", "T"));
  if (Number.isNaN(date.getTime())) {
    return null;
  }
  return limaMinutes(date);
}

function timeToMinutes(value: string) {
  const [hour, minute] = value.split(":").map((part) => Number(part));
  if (Number.isNaN(hour) || Number.isNaN(minute)) {
    return null;
  }
  return hour * 60 + minute;
}

function minutesToTime(value: number) {
  const hour = Math.floor(value / 60).toString().padStart(2, "0");
  const minute = (value % 60).toString().padStart(2, "0");
  return `${hour}:${minute}`;
}

function normalizeText(value: string) {
  return value
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "");
}

function escapeHtml(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

async function readJson(req: Request) {
  try {
    return await req.json();
  } catch (_) {
    return {};
  }
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
