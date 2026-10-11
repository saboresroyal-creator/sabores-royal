// Motor Gemini (plan gratuito de Google AI Studio, GEMINI_API_KEY). Mismo
// esquema que public/api/factura-foto.js: si un modelo está saturado o sin
// cupo, se prueba el siguiente. El historial se guarda en el formato
// "contents" de Gemini.

import { runToolCalls } from './tools-run.js';

const MODELOS = ['gemini-flash-latest', 'gemini-3.8-flash', 'gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-flash-lite-latest'];
const MAX_TOOL_ROUNDS = 6;
const TURN_BUDGET_MS = 48000; // Vercel corta la función a los 60 s
const CALL_TIMEOUT_MS = 20000;
const RETRY_STATUSES = [404, 429, 500, 503];

// Gemini usa un subconjunto de JSON Schema (tipos en mayúscula, sin
// additionalProperties). Se convierte desde la definición de las herramientas.
function toGeminiSchema(s){
  if(!s || typeof s !== 'object') return s;
  const out = {};
  if(s.type) out.type = String(s.type).toUpperCase();
  for(const k of ['description', 'enum', 'format', 'nullable']) if(s[k] !== undefined) out[k] = s[k];
  if(s.properties){
    out.properties = Object.fromEntries(Object.entries(s.properties).map(([k, v]) => [k, toGeminiSchema(v)]));
  }
  if(Array.isArray(s.required) && s.required.length) out.required = s.required;
  if(s.items) out.items = toGeminiSchema(s.items);
  return out;
}

function declarations(tools){
  return tools.map(({ def }) => {
    const hasParams = def.input_schema && def.input_schema.properties && Object.keys(def.input_schema.properties).length;
    return {
      name: def.name,
      description: def.description,
      ...(hasParams ? { parameters: toGeminiSchema(def.input_schema) } : {}),
    };
  });
}

async function callModel(modelo, body, timeoutMs){
  let r;
  try{
    r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(modelo)}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  }catch(e){
    // Tardó demasiado (modelo saturado): igual que un 503, se prueba otro.
    throw Object.assign(new Error('El modelo tardó demasiado en responder'), { status: 503 });
  }
  const json = await r.json().catch(() => ({}));
  if(!r.ok){
    throw Object.assign(new Error((json.error && json.error.message) || ('HTTP ' + r.status)), { status: r.status });
  }
  return json;
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// Las "firmas de pensamiento" de Gemini solo hacen falta dentro del turno
// en curso; se sacan al guardar para que el historial sirva aunque el
// próximo turno lo conteste otro modelo de la lista.
function stripThoughts(content){
  return {
    role: content.role,
    parts: (content.parts || [])
      .filter(p => !p.thought)
      .map(p => { const { thoughtSignature, ...rest } = p; return rest; }),
  };
}

export const geminiLLM = {
  name: 'gemini',
  available: () => !!(process.env.GEMINI_API_KEY || '').trim(),
  userTurn: (text) => ({ role: 'user', parts: [{ text }] }),
  assistantTurn: (text) => ({ role: 'model', parts: [{ text }] }),
  sanitizeForSave: (history) => history.map(stripThoughts).filter(c => c.parts.length),

  async run({ owner, system, tools, history, ctx, deadline: hardDeadline }){
    const deadline = Math.min(Date.now() + TURN_BUDGET_MS, hardDeadline || Infinity);
    const base = {
      systemInstruction: { parts: [{ text: system.join('\n\n') }] },
      tools: [{ functionDeclarations: declarations(tools) }],
      toolConfig: { functionCallingConfig: { mode: 'AUTO' } },
      generationConfig: { temperature: owner ? 0.2 : 0.4 },
    };
    const modelos = [...new Set(process.env.GEMINI_MODEL ? [process.env.GEMINI_MODEL, ...MODELOS] : MODELOS)];
    let modelo = null; // se fija en el primer pedido del turno y se mantiene

    const request = async () => {
      // Primer pedido del turno: se prueban los modelos en orden. Después se
      // sigue con el mismo (las firmas del turno son de ese modelo); si se
      // satura, se reintenta una vez.
      const candidatos = modelo ? [modelo, modelo] : modelos;
      let ultimo;
      for(let i = 0; i < candidatos.length; i++){
        const resta = deadline - Date.now();
        if(resta < 4000) break;
        try{
          const json = await callModel(candidatos[i], { ...base, contents: history }, Math.min(CALL_TIMEOUT_MS, resta));
          modelo = candidatos[i];
          return json;
        }catch(e){
          ultimo = e;
          if(!RETRY_STATUSES.includes(e.status)) throw e;
          if(modelo) await sleep(1500);
        }
      }
      throw ultimo || Object.assign(new Error('Sin tiempo para responder'), { status: 503 });
    };

    for(let round = 0; round < MAX_TOOL_ROUNDS; round++){
      const json = await request();
      const cand = (json.candidates || [])[0];
      const content = cand && cand.content && Array.isArray(cand.content.parts) && cand.content.parts.length
        ? { role: 'model', parts: cand.content.parts }
        : null;
      if(!content){
        // Bloqueado por los filtros de Google o respuesta vacía.
        return null;
      }
      history.push(content);

      const calls = content.parts.filter(p => p.functionCall).map((p, i) => ({
        id: p.functionCall.id || `call_${round}_${i}`,
        geminiId: p.functionCall.id,
        name: p.functionCall.name,
        input: p.functionCall.args || {},
      }));
      if(!calls.length){
        return content.parts.filter(p => p.text && !p.thought).map(p => p.text).join('').trim();
      }

      const results = await runToolCalls(calls, tools, ctx);
      history.push({
        role: 'user',
        parts: results.map(r => ({
          functionResponse: {
            name: r.name,
            ...(r.geminiId ? { id: r.geminiId } : {}),
            response: r.output && typeof r.output === 'object' && !Array.isArray(r.output) ? r.output : { resultado: r.output },
          },
        })),
      });
    }
    return 'Se me complicó resolver esto. ¿Me lo pedís de otra forma?';
  },
};
