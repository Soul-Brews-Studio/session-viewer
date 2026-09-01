import { describe, expect, test } from 'bun:test'
import worker from './index'
const env = { ASSETS: { fetch: async () => new Response('<!doctype html>', {headers:{'content-type':'text/html'}}) } }
describe('public static fixture',()=>{
 test('health declares no storage',async()=>{const r=await worker.fetch(new Request('https://example.test/health'),env);expect(await r.json()).toEqual({ok:true,service:'session-viewer',mode:'static-fixture',storage:'none'})})
 test('fleet and transcript shapes are deterministic',async()=>{const f:any=await (await worker.fetch(new Request('https://example.test/api/fleet'),env)).json();expect(f.fleet).toHaveLength(5);const s:any=await (await worker.fetch(new Request('https://example.test/api/session'),env)).json();expect(s.events).toHaveLength(7);expect(s.events[0].text).toContain('session-viewer')})
})
