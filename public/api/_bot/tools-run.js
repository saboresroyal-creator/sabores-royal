// Ejecuta en paralelo las herramientas que pidió el modelo (sirve para
// Claude y para Gemini). Un error de una herramienta se le devuelve al
// modelo como resultado con error, no corta la charla.

export async function runToolCalls(calls, tools, ctx){
  const byName = new Map(tools.map(t => [t.def.name, t]));
  return Promise.all(calls.map(async call => {
    const tool = byName.get(call.name);
    try{
      if(!tool) throw new Error('Herramienta desconocida: ' + call.name);
      const output = await tool.run(call.input || {}, ctx);
      return { ...call, output, isError: !!(output && output.error) };
    }catch(e){
      console.error('tool', call.name, e);
      return { ...call, output: { error: 'Error del sistema: ' + e.message }, isError: true };
    }
  }));
}
