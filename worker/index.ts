type Session = { path:string; project:string; tier:string; sessionUUID:string; agentId:string|null; agentName:string|null; workflowRunId:string|null; size:number; secondsSinceWrite:number; heat:'hot'|'warm'|'cool' }
const fleet: Session[] = [
  {path:'/fixture/projects/session-viewer/8c2a.jsonl',project:'session-viewer',tier:'session',sessionUUID:'8c2a1f90',agentId:null,agentName:null,workflowRunId:null,size:2480000,secondsSinceWrite:12,heat:'hot'},
  {path:'/fixture/projects/session-viewer/8c2a/subagents/search.jsonl',project:'session-viewer',tier:'subagent',sessionUUID:'8c2a1f90',agentId:'search-01',agentName:'search',workflowRunId:null,size:384000,secondsSinceWrite:26,heat:'warm'},
  {path:'/fixture/projects/lance-indexer/42bd.jsonl',project:'lance-indexer',tier:'session',sessionUUID:'42bd77e1',agentId:null,agentName:null,workflowRunId:null,size:1740000,secondsSinceWrite:58,heat:'warm'},
  {path:'/fixture/projects/lance-indexer/42bd/subagents/map.jsonl',project:'lance-indexer',tier:'subagent',sessionUUID:'42bd77e1',agentId:'map-02',agentName:'map',workflowRunId:null,size:212000,secondsSinceWrite:75,heat:'cool'},
  {path:'/fixture/projects/jsonl-lens/a91e.jsonl',project:'jsonl-lens',tier:'session',sessionUUID:'a91e55c0',agentId:null,agentName:null,workflowRunId:null,size:928000,secondsSinceWrite:140,heat:'cool'},
]
const lines=(path:string)=>{const project=fleet.find(s=>s.path===path)?.project??'session-viewer';return [
  ['user',`Inspect the ${project} session timeline and keep the source boundary visible.`],
  ['assistant','I will read indexed events first, then stream context from the source file.'],
  ['tool_use','search_sessions · query="timeline" · limit=20'],
  ['tool_result','12 hits · trigram route · read-only'],
  ['assistant','The hit is navigable: session id plus sequence number are retained.'],
  ['tool_use','read_context · session=fixture · seq=42 · before=4 · after=6'],
  ['assistant','Context window loaded. Scroll up to inspect earlier history.'],
].map(([type,text],i)=>({seq:i+1,lineType:type,ts:`2026-09-01T09:40:${String(i*3+1).padStart(2,'0')}.000Z`,text,summary:null,byteOffset:i*320}))}
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store','x-session-viewer-demo':'static-fixture'}})
export default {async fetch(request:Request,env:any){const u=new URL(request.url);if(u.pathname==='/health')return json({ok:true,service:'session-viewer',mode:'static-fixture',storage:'none'});if(u.pathname==='/api/status')return json({sessions:120,live:fleet.length,events:720,storage:'none'});if(u.pathname==='/api/fleet')return json({kind:'fleet',fleet,stamp:'2026-09-01T09:40:00.000Z'});if(u.pathname==='/api/session'){const path=u.searchParams.get('path')||fleet[0]!.path;return json({kind:'attached',path,events:lines(path),fromOffset:0,atTop:true,stamp:'2026-09-01T09:40:00.000Z'})}return env.ASSETS.fetch(request)}}
