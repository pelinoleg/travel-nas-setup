/* Travel-NAS web dashboard — клиент. SSE-пуш, uPlot-графики, действия, экран. */
'use strict';
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const api = (p, body) => fetch(p, body ? {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)} : undefined);
const toast = m => { const t=$('#toast'); t.textContent=m; t.classList.remove('hidden');
  clearTimeout(t._t); t._t=setTimeout(()=>t.classList.add('hidden'),2500); };
const fmtUp = s => { const d=s/86400|0,h=s%86400/3600|0,m=s%3600/60|0;
  return d?`${d}д ${h}ч`:h?`${h}ч ${m}м`:`${m}м`; };

/* ---- вкладки ---- */
$$('#tabs button').forEach(b=>b.onclick=()=>{
  $$('#tabs button').forEach(x=>x.classList.remove('active'));
  $$('.tab').forEach(x=>x.classList.remove('active'));
  b.classList.add('active'); $('#tab-'+b.dataset.tab).classList.add('active');
});

/* ---- часы ---- */
setInterval(()=>{ const d=new Date();
  $('#clock').textContent=`${('0'+d.getHours()).slice(-2)}:${('0'+d.getMinutes()).slice(-2)}`; },1000);

/* ===== график (uPlot) ===== */
let chart, chMetric='temp', chRange='24h', chData=[[],[]];
const METRICS={cpu:['CPU, %','#3b82f6'],temp:['Температура, °C','#f85149'],
  disk:['Диск, %','#3fb950'],mem:['RAM, GB','#a371f7']};
function makeChart(){
  const el=$('#chart'); el.innerHTML='';
  const [lbl,col]=METRICS[chMetric];
  chart=new uPlot({width:el.clientWidth||760,height:150,
    cursor:{show:false},legend:{show:false},
    scales:{x:{time:true}},
    axes:[{stroke:'#8b949e',grid:{stroke:'#2a3240'}},{stroke:'#8b949e',grid:{stroke:'#2a3240'}}],
    series:[{},{label:lbl,stroke:col,width:2,fill:col+'22',points:{show:false}}]},
    chData, el);
  $('#graph-title').textContent=lbl;
}
async function loadHistory(){
  try{ const r=await(await fetch(`/api/history?m=${chMetric}&range=${chRange}`)).json();
    chData=[r.t||[], r.v||[]]; chart.setData(chData);
  }catch(e){}
}
function pushLive(val){
  if(val==null) return;
  const now=Math.floor(Date.now()/1000);
  const win={'1h':3600,'24h':86400,'7d':7*86400}[chRange];
  chData[0].push(now); chData[1].push(val);
  while(chData[0].length && chData[0][0] < now-win){ chData[0].shift(); chData[1].shift(); }
  chart.setData(chData);
}
$$('.card').forEach(c=>c.onclick=()=>{
  $$('.card').forEach(x=>x.classList.remove('sel')); c.classList.add('sel');
  chMetric=c.dataset.metric; makeChart(); loadHistory();
});
$$('.ranges button').forEach(b=>b.onclick=()=>{
  $$('.ranges button').forEach(x=>x.classList.remove('active')); b.classList.add('active');
  chRange=b.dataset.range; loadHistory();
});

/* ===== рендер снимка ===== */
function setCard(id,val,sub,warn,err){
  $('#'+id).textContent=val; const v=$('#'+id).parentElement;
  v.classList.toggle('warn',!!warn); v.classList.toggle('err',!!err);
  if(sub!=null) $('#'+id+'-sub').textContent=sub;
}
function render(d){
  const s=d.system||{}, st=d.storage||{}, nw=d.network||{}, sv=d.services||{};
  setCard('cpu',s.cpu??'–',(s.load?'load '+s.load[0]:'')+' · '+(s.governor||''),s.cpu>80,s.cpu>95);
  setCard('temp',s.temp??'–',s.throttled_now?'⚠ throttle':'',s.temp>70,s.temp>80);
  setCard('disk',st.pct??'–',st.size?`${(st.used/1e12).toFixed(2)}/${(st.size/1e12).toFixed(2)} TB`:'',st.pct>85,st.pct>95||st.mounted===false);
  setCard('mem',s.mem_total?`${s.mem_used}/${s.mem_total}`:'–','GB',0,0);
  pushLive({cpu:s.cpu,temp:s.temp,disk:st.pct,mem:s.mem_used}[chMetric]);
  // сеть-индикатор
  const dot=$('#net-dot'); dot.className='dot '+(nw.ip&&nw.ip!=='?'?'ok':'err');
  dot.title=`${nw.ip||'?'} · ${nw.ssid||''} ${nw.signal?nw.signal+'dB':''}${nw.tailscale?' · TS '+nw.tailscale:''}`;
  // docker-точки
  const dk=sv.docker||[];
  $('#svc-dots').innerHTML=dk.map(c=>`<span class="s"><span class="dot ${c.state==='running'?'ok':'err'}"></span>${c.name.replace('ytarchiver-','yt-')}</span>`).join('');
  // строка бэкапа
  const nb=sv.nas_backup||{}, pr=sv.progress||{};
  $('#backup-line').textContent='NAS: '+(nb.last_status||nb.status||'—')+(pr.active?` · идёт ${pr.percent||0}%`:'');
  // storage tab
  $('#storage-body').innerHTML=kvHtml({
    'Смонтирован':st.mounted?'да':'НЕТ','Заполнение':(st.pct||0)+'%',
    'Занято':bytes(st.used),'Свободно':bytes(st.avail),'Всего':bytes(st.size),
    'Устройство':st.device||'?','Темп. диска':st.disk_temp!=null?st.disk_temp+'°C':'—','SMART':st.health||'?'});
  // docker tab
  $('#docker-body').innerHTML=dk.map(c=>`<div class="svc"><span>${c.name}</span><span class="badge ${c.state==='running'?'run':'stop'}">${c.state}</span></div>`).join('')||'<div>нет контейнеров</div>';
}
const kvHtml=o=>Object.entries(o).map(([k,v])=>`<div class="key">${k}</div><div>${v}</div>`).join('');
const bytes=b=>b?(b/1e12>=1?(b/1e12).toFixed(2)+' TB':(b/1e9).toFixed(1)+' GB'):'—';

/* ===== SSE ===== */
function connect(){
  const es=new EventSource('/api/stream');
  es.onmessage=e=>{ try{render(JSON.parse(e.data)); applyNight();}catch(_){}};
  es.onerror=()=>{ es.close(); setTimeout(connect,3000); };
}

/* ===== действия ===== */
$('#btn-power').onclick=()=>openModal('Питание',[
  ['Перезагрузить','reboot',1],['Выключить','poweroff',1]]);
function openModal(title,btns){
  $('#modal-title').textContent=title;
  $('#modal-body').innerHTML='';
  btns.forEach(([lbl,act,danger])=>{ const b=document.createElement('button');
    b.textContent=lbl; if(danger)b.className='danger';
    b.onclick=()=>{ closeModal(); doAction(act); }; $('#modal-body').appendChild(b); });
  $('#modal').classList.remove('hidden');
}
const closeModal=()=>$('#modal').classList.add('hidden');
$('#modal-cancel').onclick=closeModal;
async function doAction(name,body){
  toast('…');
  try{ const r=await(await api('/api/action/'+name,body||{})).json();
    toast(r.ok||r.detached?'OK':('Ошибка: '+(r.err||r.error||''))); }
  catch(e){ toast('Ошибка сети'); }
}
$('#btn-exit').onclick=()=>{ doAction('screen',{exit_kiosk:true}); };
$('#act-update').onclick=()=>doAction('update');
$('#act-boost').onclick=()=>doAction('cpu-boost');
$$('#powermode button').forEach(b=>b.onclick=()=>{
  $$('#powermode button').forEach(x=>x.classList.remove('active')); b.classList.add('active');
  doAction('power-mode',{mode:b.dataset.mode}); });
$('#rotate-apply').onclick=()=>{ const v=$('#rotate').value; if(v) doAction('screen',{rotate:v}); };

/* ===== экран: яркость, гашение по таймауту, ночь ===== */
const LS=localStorage;
const brightness=$('#brightness'), bval=$('#brightness-val');
function setBrightness(v,save){ bval.textContent=v; api('/api/action/screen',{brightness:+v});
  if(save) LS.brightness=v; }
brightness.value=LS.brightness||200; bval.textContent=brightness.value;
brightness.oninput=()=>setBrightness(brightness.value,true);
$('#screen-timeout').value=LS.screenTimeout||'300';
$('#screen-timeout').onchange=e=>LS.screenTimeout=e.target.value;
['night-from','night-to','night-level'].forEach(id=>{ const el=$('#'+id);
  if(LS[id])el.value=LS[id]; el.onchange=()=>{LS[id]=el.value; nightApplied=null;}; });

let lastAct=Date.now(), screenOff=false;
['pointerdown','touchstart','keydown','mousemove'].forEach(ev=>
  addEventListener(ev,()=>{ lastAct=Date.now();
    if(screenOff){ screenOff=false; api('/api/action/screen',{backlight:'on'});
      setBrightness(brightness.value); } },{passive:true}));
setInterval(()=>{ const to=+($('#screen-timeout').value||0);
  if(to>0 && !screenOff && Date.now()-lastAct>to*1000){
    screenOff=true; api('/api/action/screen',{backlight:'off'}); } },2000);

let nightApplied=null;
function applyNight(){
  const from=$('#night-from').value, to=$('#night-to').value;
  if(!from||!to) return;
  const now=new Date(), cur=('0'+now.getHours()).slice(-2)+':'+('0'+now.getMinutes()).slice(-2);
  const inWin = from<to ? (cur>=from&&cur<to) : (cur>=from||cur<to);
  const target = inWin ? Math.round(+$('#night-level').value/100*255) : +brightness.value;
  if(!screenOff && target!==nightApplied){ nightApplied=target;
    api('/api/action/screen',{brightness:target}); }
}

/* ===== старт ===== */
makeChart(); loadHistory(); connect();
setInterval(loadHistory, 60000);
addEventListener('resize',()=>{makeChart();chart.setData(chData);});
setBrightness(brightness.value);
