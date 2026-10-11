// Motor Claude (si hay ANTHROPIC_API_KEY). El historial se guarda en el
// formato de mensajes de Anthropic.

import Anthropic from '@anthropic-ai/sdk';
import { runToolCalls } from './tools-run.js';

const MODEL = 'claude-opus-5-5';
const MAX_TOOL_ROUNDS = 8;

export const claudeLLM = {
  name: 'claude',
  available: () => !!(process.env.ANTHROPIC_API_KEY || '').trim(),
  userTurn: (text) => ({ role: 'user', content: text }),
  assistantTurn: (text) => ({ role: 'assistant', content: text }),
  sanitizeForSave: (history) => history,

  async run({ owner, system, tools, history, ctx }){
    const client = new Anthropic();
    for(let round = 0; round < MAX_TOOL_ROUNDS; round++){
      const response = await client.beta.messages.create({
        model: MODEL,
        max_tokens: 16000,
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
        output_config: { effort: owner ? 'medium' : 'low' },
        cache_control: { type: 'ephemeral' },
        system: system.map(text => ({ type: 'text', text })),
        tools: tools.map(t => t.def),
        messages: history,
      });
      history.push({ role: 'assistant', content: response.content });

      if(response.stop_reason === 'refusal') return null;
      if(response.stop_reason !== 'tool_use'){
        return response.content.filter(b => b.type === 'text').map(b => b.text).join('\n').trim();
      }

      const calls = response.content.filter(b => b.type === 'tool_use').map(b => ({ id: b.id, name: b.name, input: b.input }));
      const results = await runToolCalls(calls, tools, ctx);
      history.push({
        role: 'user',
        content: results.map(r => ({
          type: 'tool_result',
          tool_use_id: r.id,
          content: JSON.stringify(r.output),
          ...(r.isError ? { is_error: true } : {}),
        })),
      });
    }
    return 'Se me complicó resolver esto. ¿Me lo pedís de otra forma?';
  },
};
