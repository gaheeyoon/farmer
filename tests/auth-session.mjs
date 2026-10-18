import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { randomUUID } from 'node:crypto';
const source = fs.readFileSync(new URL('../farmer-api.js', import.meta.url), 'utf8');
const DAY = 86400000;
const token = n => ({ access_token: `test-access-${n}`, refresh_token: `test-refresh-${n}`, expires_in: 3600 });
const response = (value, status = 200) => ({ok: status < 400, status, json: async () => value});
function browser() {
  const data = new Map(), tabs = []; let now = Date.now(), queue = Promise.resolve(), rotations = 0;
  const calls = [];
  const b = { data, calls, setTime: v => now = v, time: () => now, advance: days => now += days * DAY,
    handler: async (url) => {
      if (url.includes('grant_type=password')) return response(token('login'));
      if (url.includes('grant_type=refresh_token')) return response(token(++rotations));
      return response({ok:true});
    },
    tab({locked = true, storageBlocked = false} = {}) {
      const win = new EventTarget(); win.FARMER_BACKEND = {enabled:true,url:'https://example.supabase.co',publishableKey:'public-test'};
      const emit = key => tabs.filter(t => t.win !== win).forEach(t => { const e = new Event('storage'); e.key = key; t.win.dispatchEvent(e); });
      const localStorage = {
        getItem: k => { if (storageBlocked) throw new Error('blocked'); return data.get(k) ?? null; },
        setItem: (k,v) => { if (storageBlocked) throw new Error('blocked'); data.set(k,v); emit(k); },
        removeItem: k => { if (storageBlocked) throw new Error('blocked'); data.delete(k); emit(k); },
      };
      const nav = locked ? {locks:{request: (_name, work) => {
        const run = queue.catch(() => {}).then(work); queue = run; return run;
      }}} : {};
      const context = vm.createContext({window:win,localStorage,navigator:nav,crypto:{randomUUID},Event,AbortController,
        setTimeout,clearTimeout,URLSearchParams,TypeError,
        Date: class extends Date { static now() { return now; } },
        location:{origin:'https://example.test',pathname:'/farmer/admin',search:'',hash:''},history:{replaceState(){}},
        fetch:async(url,opts) => { calls.push({url,body:JSON.parse(opts.body || '{}'),headers:opts.headers}); return b.handler(url,opts); }
      });
      vm.runInContext(source,context);
      const tab = {win,api:win.FarmerAPI,context,localStorage}; tabs.push(tab); return tab;
    },
    saved: () => JSON.parse([...data.values()][0]),
    replace: value => { const key = [...data.keys()][0]; data.set(key,JSON.stringify(value)); },
  }; return b;
}
const login = tab => tab.api.signIn('admin@example.test','only-a-test-password');
const refreshCalls = b => b.calls.filter(c => c.url.includes('grant_type=refresh_token'));
{
  const b=browser(), a=b.tab(); await login(a);
  const first=b.saved();
  assert.equal(first.deadline-b.time(),14*DAY);
  assert.deepEqual(Object.keys(first).sort(),['id','access_token','refresh_token','expires_at','deadline'].sort());
  assert.ok(!JSON.stringify(first).includes('password'));
  const reload=b.tab(); assert.equal(reload.api.restoreSession(),true);
  await reload.api.admin('summary'); assert.equal(refreshCalls(b).length,0);
  b.advance(8); const reopen=b.tab(); assert.equal(reopen.api.restoreSession(),true);
  await reopen.api.admin('summary');
  assert.equal(refreshCalls(b).length,1); assert.equal(b.saved().deadline,first.deadline);
  assert.equal(b.calls.at(-1).headers.Authorization,'Bearer test-access-1');
  b.advance(7); assert.equal(reopen.api.restoreSession(),false); assert.equal(b.data.size,0);
  await assert.rejects(reopen.api.admin('summary'),e=>e.authRequired);
  console.log('PASS reload/browser reopen, day 8 rotation, fixed day 14 expiry, minimal storage');
}
{
  const b=browser(), a=b.tab(); await login(a); const second=b.tab(); second.api.restoreSession(); b.advance(8);
  await Promise.all([a.api.admin('summary'),a.api.admin('list'),second.api.admin('summary')]);
  assert.equal(refreshCalls(b).length,1);
  assert.equal(b.calls.filter(c=>c.url.includes('/rpc/')).every(c=>c.headers.Authorization==='Bearer test-access-1'),true);
  await second.api.signOut(); assert.equal(a.api.hasSession(),false); assert.equal(b.data.size,0);
  assert.equal(b.calls.at(-1).url.endsWith('logout?scope=local'),true);
  console.log('PASS same-tab/cross-tab rotation lock and shared logout');
}
for (const failure of ['offline',503,429]) {
  const b=browser(), a=b.tab(); await login(a); b.advance(8); const before=b.saved(); const handler=b.handler;
  b.handler=async url=>{if(url.includes('refresh_token')){if(failure==='offline')throw new TypeError('offline');return response({message:'retry'},failure);}return handler(url);};
  await assert.rejects(a.api.admin('summary'));
  assert.equal(b.saved().refresh_token,before.refresh_token); assert.equal(a.api.hasSession(),true);
  b.handler=handler; await a.api.admin('summary'); assert.equal(b.saved().deadline,before.deadline);
}
console.log('PASS offline, server failure and rate limit retain login for retry');
{
  const b=browser(), a=b.tab(); await login(a); b.advance(8);
  b.handler=async()=>response({error_code:'refresh_token_already_used',message:'invalid'},400);
  await assert.rejects(a.api.admin('summary'),e=>e.authRequired); assert.equal(b.data.size,0);
  console.log('PASS revoked refresh token clears persisted login');
}
{
  const b=browser(), a=b.tab(); await login(a); b.advance(8); let resolve, started;
  const wait=new Promise(r=>started=r), handler=b.handler;
  b.handler=url=>url.includes('refresh_token') ? (started(),new Promise(r=>resolve=r)) : handler(url);
  const pending=a.api.admin('summary'); await wait; await a.api.signOut(); resolve(response(token('late')));
  await assert.rejects(pending,e=>e.authRequired); assert.equal(b.data.size,0); assert.equal(a.api.hasSession(),false);
  console.log('PASS logout during refresh cannot restore an ended session');
}
{
  const b=browser(), a=b.tab(); await login(a); b.advance(8); let resolve, started;
  const wait=new Promise(r=>started=r), handler=b.handler;
  b.handler=url=>url.includes('refresh_token') ? (started(),new Promise(r=>resolve=r)) : handler(url);
  const pending=a.api.admin('summary'); await wait;
  const other=b.tab(); other.api.restoreSession(); await other.api.signOut();
  resolve(response(token('late'))); await assert.rejects(pending,e=>e.authRequired); assert.equal(b.data.size,0);
  console.log('PASS cross-tab logout cancels an in-flight refresh');
}
{
  const b=browser(), a=b.tab(); await login(a); b.handler=async()=>response({message:'forbidden'},403);
  await assert.rejects(a.api.admin('summary'),e=>e.authRequired); assert.equal(b.data.size,0);
  const malformed=b.tab(); b.data.set('farmer-admin-session:https://example.supabase.co:v1','not-json');
  assert.equal(malformed.api.restoreSession(),false);
  const blocked=b.tab({storageBlocked:true}); b.handler=async()=>response(token('blocked'));
  await login(blocked); assert.equal(blocked.api.hasSession(),true); assert.equal(blocked.api.persistsSession(),false);
  console.log('PASS denied admin, corrupt storage and storage-blocked fallback');
}
{
  const b=browser(), a=b.tab();
  a.context.location.hash='#access_token=callback-token&refresh_token=callback-refresh&expires_in=3600';
  let cleaned=false; a.context.history.replaceState=()=>cleaned=true;
  assert.equal(a.api.consumeCallback(),true); assert.equal(cleaned,true);
  assert.equal(b.tab().api.restoreSession(),true);
  await a.api.rpc('catalog'); assert.equal(b.calls.at(-1).headers.Authorization,undefined);
  console.log('PASS confirmation callback persists login; public requests remain anonymous');
}
