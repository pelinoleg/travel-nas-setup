/* Travel-NAS web dashboard — client. */
'use strict';
/* UI-настройки храним на сервере (переживают ребут; localStorage в kiosk теряется
   при kill'е). Синхронно подтягиваем их в localStorage ДО инициализации. */
try{const _x=new XMLHttpRequest();_x.open('GET','/api/ui',false);_x.send();
  if(_x.status===200){const u=JSON.parse(_x.responseText||'{}');for(const k in u)localStorage[k]=u[k];}}catch(e){}
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const api=(p,b)=>fetch(p,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:undefined);
const uiSet=(k,v)=>{localStorage[k]=v;try{api('/api/ui',{[k]:String(v)});}catch(e){}};
const toast=m=>{const t=$('#toast');t.textContent=m;t.classList.remove('hidden');clearTimeout(t._t);t._t=setTimeout(()=>t.classList.add('hidden'),2500);};
const fmtUp=s=>{const d=s/86400|0,h=s%86400/3600|0,m=s%3600/60|0;return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m`;};
const TB=b=>b==null?'?':(b>=1e12?(b/1e12).toFixed(1)+' TB':b>=1e9?Math.round(b/1e9)+' GB':(b/1e6).toFixed(0)+' MB');
const ic=n=>`<svg class="ic"><use href="#${n}"/></svg>`;

const MET={cpu:{label:'CPU %',col:'#3b82f6',max:100,th:[70,85,95]},
  temp:{label:'Temperature °C',col:'#f85149',max:100,th:[60,72,82]},
  mem:{label:'RAM GB',col:'#a371f7',max:null,th:null},
  net_rx:{label:'Download',col:'#3fb950',max:null,th:null},
  disk:{label:'Disk %',col:'#22d3ee',max:100,th:[75,88,95]},
  dtemp:{label:'Disk temp °C',col:'#fb923c',max:70,th:[45,52,58]}};
const fmtNet=k=>{k=k||0;return k>=1000?(k/1000).toFixed(1)+' MB/s':Math.round(k)+' KB/s';};
let memTotal=8, last={}, activeTab='overview';
const lvl=(m,v)=>{const t=MET[m]&&MET[m].th;if(!t||v==null)return'';return v>=t[2]?'lv-crit':v>=t[1]?'lv-high':v>=t[0]?'lv-warn':'';};
const colorVal=(id,m,v)=>{const e=$('#'+id);if(!e)return;e.classList.remove('lv-warn','lv-high','lv-crit');const c=lvl(m,v);if(c)e.classList.add(c);};

/* tabs */
let prePhotoBright=null;
function switchTab(t){const prev=activeTab;
  $$('#tabs button').forEach(x=>x.classList.toggle('active',x.dataset.tab===t));
  $$('.tab').forEach(x=>x.classList.toggle('active',x.id==='tab-'+t));activeTab=t;
  if(t==='photos'&&prev!=='photos'){prePhotoBright=+br.value||80;api('/api/action/screen',{brightness:'100%'});}
  else if(prev==='photos'&&t!=='photos'&&prePhotoBright!=null){api('/api/action/screen',{brightness:prePhotoBright+'%'});prePhotoBright=null;}
  if(t==='storage')renderDisks();else if(t==='apps')renderApps();else if(t==='settings')loadPiBackup();else if(t==='events')renderEvents();else if(t==='photos')renderPhotos();}
const EVCATS=[{k:'yt',label:'YouTube',ic:'i-video'},{k:'nas',label:'NAS backup',ic:'i-cloud'},{k:'photo',label:'Photo import',ic:'i-camera'},{k:'system',label:'System',ic:'i-settings'},{k:'thermal',label:'Thermal',ic:'i-thermo'}];
let _evCache=[];
async function renderEvents(){let ev=[];
  try{ev=await(await fetch('/api/events')).json();}catch(e){}
  _evCache=ev.filter(e=>e.ts).sort((a,b)=>b.ts-a.ts);
  drawEvents();   // показываем системные/наши сразу, не дожидаясь YT
  try{const c=new AbortController(),tm=setTimeout(()=>c.abort(),3500);
    const y=await(await fetch(`http://${location.hostname}:8081/api/events`,{signal:c.signal})).json();clearTimeout(tm);
    (Array.isArray(y)?y:[]).slice(0,40).forEach(e=>{const ts=Math.floor(Date.parse((e.created_at||e.timestamp||e.time||'').replace(' ','T'))/1000)||0;
      const ty=(e.type||'').replace(/_/g,' ');
      ev.push({ts,type:'yt',title:(e.video_title||e.message||ty||'YT event'),sub:(e.channel_name||'')+(ty?' · '+ty:''),level:/err|fail/i.test(e.type||e.level||'')?'crit':'ok'});});
    _evCache=ev.filter(e=>e.ts).sort((a,b)=>b.ts-a.ts);drawEvents();}catch(e){}}
function evHidden(){return new Set((localStorage.ev_hidden||'').split(',').filter(Boolean));}
function drawEvents(){const ev=_evCache,hid=evHidden(),filt=$('#ev-filters'),body=$('#events-body');if(!body)return;
  if(filt){filt.innerHTML=EVCATS.map(c=>{const n=ev.filter(e=>e.type===c.k).length;return `<button class="evchip ${hid.has(c.k)?'off':''}" data-k="${c.k}">${ic(c.ic)}${c.label}<span class="evn">${n}</span></button>`;}).join('');
    $$('#ev-filters .evchip').forEach(b=>b.onclick=()=>{const k=b.dataset.k,h=evHidden();h.has(k)?h.delete(k):h.add(k);uiSet('ev_hidden',[...h].join(','));drawEvents();});}
  const dt=ts=>{const d=new Date(ts*1000),t=new Date(),y=new Date();y.setDate(t.getDate()-1);const s=(a,b)=>a.toDateString()===b.toDateString();
    const hm=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);
    return (s(d,t)?'Today':s(d,y)?'Yest':d.toLocaleDateString('en-GB',{day:'2-digit',month:'short'}))+' '+hm;};
  let h='';
  EVCATS.forEach(c=>{if(hid.has(c.k))return;const items=ev.filter(e=>e.type===c.k);if(!items.length)return;
    h+=`<div class="evcat c-${c.k}"><div class="evcat-title"><span class="evdot">${ic(c.ic)}</span><div><div class="evct">${c.label}</div><div class="evcn">${items.length} events</div></div></div><div class="evcat-list">`;
    items.slice(0,40).forEach(e=>{h+=`<div class="evrow"><span class="evlvl ${e.level||'ok'}"></span><div class="evbody"><div class="evtitle">${(e.title||'').slice(0,80)}</div>${e.sub?'<div class="evsub">'+e.sub+'</div>':''}</div><span class="evtime">${dt(e.ts)}</span></div>`;});
    h+=`</div></div>`;});
  $('#events-body').innerHTML=h||'<div class="note">no events (all categories hidden?)</div>';}

/* ===== Photos ===== */
let phFiles=[],phIdx=0,phSession='';
const phExifOn=()=>localStorage.phExif!=='0';
async function renderPhotos(){
  const nw=last.network||{},addr=(nw.ip&&nw.ip!=='?')?nw.ip:((nw.host||'nas')+'.local');
  $('#ph-hint').textContent='📱 '+addr+':8090';
  let sess=[];try{sess=await(await fetch('/api/photos/sessions')).json();}catch(e){}
  const sel=$('#ph-sel');
  if(!sess.length){sel.innerHTML='';$('#ph-grid').innerHTML='<div class="note">no imports yet — insert an SD card</div>';$('#ph-count').textContent='';return;}
  sel.innerHTML=sess.map(s=>`<option value="${s.id}">${s.date} · ${s.name} (${s.count})</option>`).join('');
  phSession=(localStorage.phSession&&sess.find(s=>s.id===localStorage.phSession))?localStorage.phSession:sess[0].id;
  sel.value=phSession;
  sel.onchange=()=>{phSession=sel.value;uiSet('phSession',phSession);loadPhotoGrid();};
  loadPhotoGrid();}
async function loadPhotoGrid(){
  const g=$('#ph-grid');g.innerHTML='<div class="note">loading…</div>';
  try{phFiles=await(await fetch('/api/photos/list?session='+encodeURIComponent(phSession))).json();}catch(e){phFiles=[];}
  $('#ph-count').textContent=phFiles.length+' photos';
  if(!phFiles.length){g.innerHTML='<div class="note">empty</div>';return;}
  const ts=localStorage.phThumb||400;
  g.innerHTML=phFiles.map((f,i)=>`<div class="phcell" data-i="${i}"><img loading="lazy" src="/api/photos/img?s=${ts}&f=${encodeURIComponent(f.f)}"></div>`).join('');
  $$('#ph-grid .phcell').forEach(c=>c.onclick=()=>openPhoto(+c.dataset.i));}
function openPhoto(i){phIdx=i;$('#ph-view').classList.remove('hidden');showPhoto();}
function closePhoto(){$('#ph-view').classList.add('hidden');$('#pv-img').src='';loadPhotoGrid();}
function showPhoto(){const f=phFiles[phIdx];if(!f){closePhoto();return;}
  $('#pv-stage').classList.remove('zoomed');
  $('#pv-img').src='/api/photos/img?s=1920&f='+encodeURIComponent(f.f);
  $('#pv-name').textContent=f.name;$('#pv-pos').textContent=(phIdx+1)+' / '+phFiles.length;
  $('#pv-prev').classList.toggle('hidden',phIdx<=0);$('#pv-nextarr').classList.toggle('hidden',phIdx>=phFiles.length-1);
  loadPhotoExif();}
async function loadPhotoExif(){const p=$('#pv-exif');p.classList.toggle('hidden',!phExifOn());if(!phExifOn())return;
  p.innerHTML='…';let d={};try{d=await(await fetch('/api/photos/exif?f='+encodeURIComponent(phFiles[phIdx].f))).json();}catch(e){}
  const it=(v,suf)=>v?`<span>${v}${suf||''}</span>`:'';
  p.innerHTML=(it(d.Model)+it(d.LensModel)+it(d.FNumber&&'ƒ/'+d.FNumber)+it(d.ExposureTime&&d.ExposureTime+'s')+it(d.ISO&&'ISO '+d.ISO)+it(d.FocalLength)+it(d.ImageSize)+it(d.DateTimeOriginal))||'<span>no EXIF</span>';}
function navPhoto(d){const n=phIdx+d;if(n>=0&&n<phFiles.length){phIdx=n;showPhoto();}}
function toggleZoom(){const st=$('#pv-stage'),z=st.classList.toggle('zoomed'),f=phFiles[phIdx];if(!f)return;
  $('#pv-img').src='/api/photos/img?s='+(z?'full':'1920')+'&f='+encodeURIComponent(f.f);}
function photoAct(act){const f=phFiles[phIdx];if(!f)return;
  if(act==='delete'){api('/api/photos/action',{f:f.f,action:'delete'});toast('rejected → _rejected');
    phFiles.splice(phIdx,1);if(!phFiles.length){closePhoto();return;}if(phIdx>=phFiles.length)phIdx=phFiles.length-1;showPhoto();return;}
  if(act==='save'){const b={f:f.f,action:'save'};if(localStorage.phTg==='1')b.tg=true;api('/api/photos/action',b);toast(localStorage.phTg==='1'?'saved + Telegram':'saved → _selects');}
  if(phIdx<phFiles.length-1){phIdx++;showPhoto();}else closePhoto();}
$('#pv-close').onclick=closePhoto;$('#pv-prev').onclick=()=>navPhoto(-1);$('#pv-nextarr').onclick=()=>navPhoto(1);
$('#pv-next').onclick=()=>photoAct('next');$('#pv-del').onclick=()=>photoAct('delete');$('#pv-save').onclick=()=>photoAct('save');
$('#pv-exif-btn').onclick=()=>{uiSet('phExif',phExifOn()?'0':'1');loadPhotoExif();};
$('#pv-stage').addEventListener('dblclick',toggleZoom);
{let sx=0;const st=$('#pv-stage');
 st.addEventListener('touchstart',e=>sx=e.touches[0].clientX,{passive:true});
 st.addEventListener('touchend',e=>{if(st.classList.contains('zoomed'))return;const dx=e.changedTouches[0].clientX-sx;if(Math.abs(dx)>60)navPhoto(dx<0?1:-1);},{passive:true});}
$$('#tabs button').forEach(b=>b.onclick=()=>switchTab(b.dataset.tab));
setInterval(()=>{const d=new Date();$('#clock').textContent=`${('0'+d.getHours()).slice(-2)}:${('0'+d.getMinutes()).slice(-2)}`;},1000);

/* pages */
function openPage(id){$$('.page').forEach(p=>p.classList.add('hidden'));$('#'+id).classList.remove('hidden');
  ({'page-power':renderPower,'page-photo':renderPhotoPage,'page-nas':renderNasPage,'page-logs':loadLogs,'page-network':renderNetwork,
    'page-services':renderServices,'page-yt':renderYT,'page-configs':renderConfigs,'page-today':renderToday,
    'page-failed':renderFailed,'page-docker':renderProjects,'page-disk':renderDiskPage,'page-ambient':renderAmbientSettings}[id]||(()=>{}))();}
const closePages=()=>$$('.page').forEach(p=>p.classList.add('hidden'));
$$('.page .back').forEach(b=>b.onclick=closePages);
$$('[data-open]').forEach(el=>el.onclick=()=>{const o=el.dataset.open;
  if(o==='detail')openDetail(el.dataset.metric);else openPage(o);});

/* sparklines */
const TBUF=[],SPARK={cpu:[],temp:[],mem:[],net_rx:[],disk:[],dtemp:[]};
const sparkMax=(m,arr)=>MET[m].max||(m==='mem'?memTotal:Math.max(1,...arr,0.1));
const sparkWin=m=>+(localStorage['spark_'+m]||300);  /* сек, настраивается в Settings */
function winStart(m){const w=sparkWin(m),now=TBUF.length?TBUF[TBUF.length-1]:0;let i=0;while(i<TBUF.length&&TBUF[i]<now-w)i++;return i;}
function drawSpark(cv,arr,color,max){const w=cv.width=cv.clientWidth*2,h=cv.height=cv.clientHeight*2;
  const x=cv.getContext('2d');x.clearRect(0,0,w,h);if(arr.length<2)return;
  x.beginPath();arr.forEach((v,i)=>{const px=i/(arr.length-1)*w,py=h-Math.min(1,v/max)*(h-6)-3;i?x.lineTo(px,py):x.moveTo(px,py);});
  x.strokeStyle=color;x.lineWidth=2;x.lineJoin='round';x.stroke();x.lineTo(w,h);x.lineTo(0,h);x.closePath();x.fillStyle=color+'33';x.fill();}
const SPARKHIST={};  /* metric -> {t,v} для длинных окон (>15м) из history-sqlite */
const histRange=w=>w<=3600?'1h':w<=86400?'24h':'7d';
async function fetchSparkHist(m){if(sparkWin(m)<=900)return;
  try{const r=await(await fetch(`/api/history?m=${m}&range=${histRange(sparkWin(m))}`)).json();SPARKHIST[m]={t:r.t||[],v:r.v||[]};updateSparks();}catch(e){}}
function heatColor(k,v){const t=MET[k].th;if(!t)return MET[k].col;return v>=t[2]?'#f85149':v>=t[1]?'#f0883e':v>=t[0]?'#d29922':'#3fb950';}
function updateSparks(){$$('.spark').forEach(cv=>{const k=cv.dataset.s;if(!SPARK[k])return;const w=sparkWin(k);let arr;
  if(w<=900)arr=SPARK[k].slice(winStart(k));
  else{const h=SPARKHIST[k];if(h&&h.t.length){const now=h.t[h.t.length-1];let i=0;while(i<h.t.length&&h.t[i]<now-w)i++;arr=h.v.slice(i).filter(x=>x!=null);}else arr=SPARK[k].slice(winStart(k));}
  const col=(k==='temp'||k==='dtemp')?heatColor(k,arr.length?arr[arr.length-1]:0):MET[k].col;
  drawSpark(cv,arr,col,sparkMax(k,arr));});}
setInterval(()=>['cpu','temp','mem','net_rx','disk','dtemp'].forEach(m=>{if(sparkWin(m)>900)fetchSparkHist(m);}),60000);

/* живой широкий график CPU+Temp (низ главного). Период настраивается в Settings. */
let ovChart=null,OVT=[],OVC=[],OVTEMP=[];
const ovWin=()=>+(localStorage.ov_period||3600);
async function initOvChart(){const el=$('#ovchart-c');if(!el||typeof uPlot==='undefined')return;
  const w=ovWin(),lgr=$('#ovchart-wrap .lgr');if(lgr)lgr.textContent='last '+fmtPer(w);
  try{const r=histRange(w),[c,t]=await Promise.all([fetch('/api/history?m=cpu&range='+r).then(x=>x.json()),fetch('/api/history?m=temp&range='+r).then(x=>x.json())]);
    OVT=c.t||[];OVC=c.v||[];OVTEMP=(t.v||[]).slice(0,OVT.length);
    const now=Date.now()/1000|0;let i=0;while(i<OVT.length&&OVT[i]<now-w)i++;OVT=OVT.slice(i);OVC=OVC.slice(i);OVTEMP=OVTEMP.slice(i);}catch(e){}
  if(ovChart){ovChart.destroy();ovChart=null;}el.innerHTML='';
  ovChart=new uPlot({width:el.clientWidth||760,height:el.clientHeight||62,cursor:{show:false},legend:{show:false},
    scales:{x:{time:true},y:{range:[0,100]}},axes:[{show:false},{show:false}],
    series:[{},{stroke:'#3b82f6',width:1.3,points:{show:false}},{stroke:'#f85149',width:1.3,points:{show:false}}]},
    ovData(),el);}
/* прорежаем (усредняем) до ~200 точек — иначе на больших периодах сплошная каша */
function ovData(){const max=200;if(OVT.length<=max)return[OVT,OVC,OVTEMP];
  const step=OVT.length/max,T=[],C=[],M=[];
  for(let i=0;i<max;i++){const a=Math.floor(i*step),b=Math.max(a+1,Math.floor((i+1)*step));
    let sc=0,nc=0,sm=0,nm=0;for(let j=a;j<b;j++){if(OVC[j]!=null){sc+=OVC[j];nc++;}if(OVTEMP[j]!=null){sm+=OVTEMP[j];nm++;}}
    T.push(OVT[a]);C.push(nc?sc/nc:null);M.push(nm?sm/nm:null);}
  return[T,C,M];}
function pushOv(s){if(!ovChart)return;const now=Date.now()/1000|0;OVT.push(now);OVC.push(s.cpu||0);OVTEMP.push(s.temp||0);
  const cut=now-ovWin();while(OVT.length&&OVT[0]<cut){OVT.shift();OVC.shift();OVTEMP.shift();}
  ovChart.setData(ovData());}

/* render */
const chip=(cls,txt)=>`<span class="chip"><span class="dot ${cls}"></span>${txt}</span>`;
function whichBackup(pr){if(!pr||!pr.active)return null;return pr.kind||'photo';}
function render(d){last=d;const s=d.system||{},st=d.storage||{},nw=d.network||{},sv=d.services||{};
  if(s.mem_total)memTotal=s.mem_total;
  const memPct=s.mem_total?Math.round(s.mem_used/s.mem_total*100):null;
  $('#cpu').textContent=s.cpu!=null?Math.round(s.cpu):'–';colorVal('cpu','cpu',s.cpu);
  $('#temp').textContent=s.temp!=null?Math.round(s.temp):'–';colorVal('temp','temp',s.temp);
  $('#mem').textContent=s.mem_total?(+s.mem_used).toFixed(1):'–';$('#mem-tot').textContent=s.mem_total?'/'+Math.round(s.mem_total)+' GB':'';colorVal('mem','disk',memPct);
  {const tx=s.net_tx||0,rx=s.net_rx||0;
   $('#net').innerHTML=`<span class="dl ${rx>=1?'on':''}">${ic('i-dl')}${fmtNet(rx)}</span><span class="ul ${tx>=1?'on':''}">${ic('i-ul')}${fmtNet(tx)}</span>`;}
  const dkTile=$('#disk').closest('.tile'),unmounted=st.mounted===false,ro=st.readonly;
  if(dkTile)dkTile.classList.toggle('alarm',unmounted||ro);
  if(unmounted){$('#disk').innerHTML='<span class="lv-crit">✕</span>';$('#disk-sub').innerHTML='<span class="lv-crit" style="font-weight:700">NOT MOUNTED</span>';}
  else if(ro){$('#disk').textContent=st.pct??'–';$('#disk-sub').innerHTML='<span class="lv-crit" style="font-weight:700">READ-ONLY</span>';}
  else{$('#disk').textContent=st.pct??'–';$('#disk-sub').textContent=st.size?`${(st.used/1e12).toFixed(2)} / ${(st.size/1e12).toFixed(2)} TB`:'';}
  colorVal('disk','disk',st.pct);
  const dbar=$('#disk-bar');if(dbar){dbar.style.width=(unmounted?0:st.pct||0)+'%';dbar.className=st.pct>=95?'crit':st.pct>=88?'high':st.pct>=75?'warn':'';}
  const dtemp=$('#disk-temp'),dt=st.disk_temp;
  if(dt!=null&&!unmounted){dtemp.textContent=dt+'°';dtemp.className='dtemp '+(dt>=58?'crit':dt>=52?'high':dt>=45?'warn':'');}else dtemp.textContent='';
  const pt=$('#power-tile');if(pt){pt.className='tile';pt.classList.add('pm-'+(s.pmode||'auto'));}
  $('#power').textContent=s.pmode||'auto';$('#power-sub').textContent=s.governor||'?';
  {const fr=$('#freq');if(fr){fr.textContent=s.freq_mhz||'–';const frac=(s.freq_mhz||0)/(s.freq_max||1800);
    fr.className=frac>=.9?'f-full':frac>=.6?'f-mid':frac>=.35?'f-low':'f-min';}}
  $('#uptime').textContent='up '+fmtUp(s.uptime||0);
  {const ap=nw.mode==='AP',sig=nw.signal,q=sig!=null?Math.max(0,Math.min(100,2*(sig+100))):null;  // dBm→~%
   $('#wifi-v').textContent=ap?'Hotspot':(nw.ssid||'—');
   const ts=nw.ts_up?` · <span style="color:var(--ok)">TS ✓</span>`:'';
   $('#wifi-sub').innerHTML=ap?(nw.ap_ssid||nw.ap_name||''):`${q!=null?q+'%':'—'} · ${nw.ip&&nw.ip!=='?'?nw.ip:'no ip'}${ts}`;
   const wd=$('#wifi-dot');if(wd)wd.className='tdot '+(ap?'warn':(nw.ip&&nw.ip!=='?'?'ok':'crit'));}
  // docker tile — проекты + контейнеры
  const proj=sv.projects||[],down=proj.filter(p=>p.running<p.total).length;
  const totC=proj.reduce((a,p)=>a+p.total,0),runC=proj.reduce((a,p)=>a+p.running,0);
  $('#dk').innerHTML=`${runC}<span class="u2">/${totC}</span>`;
  $('#dk').className='tv2 '+(!proj.length?'':(down?'lv-crit':'lv-ok'));
  $('#dk-sub').innerHTML=`${proj.length} stacks · ${down?'<span style="color:var(--crit)">'+down+' down</span>':'<span style="color:var(--ok)">all up</span>'}`;
  $('#dk-dot').className='tdot '+(!proj.length?'':(down?'crit':'ok'));
  // yt tile
  const yt=sv.yt||{};
  if(Object.keys(yt).length){$('#yt-v').innerHTML=`${yt.videos||0}<span class="u2"> vids</span>`;
    {const bits=[`${yt.pending||0} queued`];if(yt.error)bits.push(`<span style="color:var(--crit)">${yt.error} err</span>`);
     if(yt.downloading)bits.push(`<span style="color:var(--ok)">${yt.downloading} dl</span>`);else if(yt.paused)bits.push(`<span style="color:var(--warn)">paused</span>`);
     $('#yt-sub').innerHTML=bits.join(' · ');}
    $('#yt-dot').className='tdot '+(yt.paused?'warn':(yt.downloading?'ok':''));
    const dl=$('#yt-dl');if(dl){if(yt.downloading>0){dl.innerHTML=ic('i-dl')+yt.downloading;dl.className='dlbadge on';}else dl.className='dlbadge';}
    const ytt=$('#yt-v').closest('.tile');if(ytt)ytt.classList.toggle('dl-active',yt.downloading>0);}
  else{$('#yt-v').textContent='–';$('#yt-sub').textContent='offline';$('#yt-dot').className='tdot';const dl=$('#yt-dl');if(dl)dl.className='dlbadge';const ytt=$('#yt-v').closest('.tile');if(ytt)ytt.classList.remove('dl-active');}
  // backups tiles (photo/nas раздельно)
  renderBackupTiles(sv);
  // buffers + sparks
  TBUF.push(Date.now()/1000|0);
  [['cpu',s.cpu],['temp',s.temp],['mem',s.mem_used],['net_rx',s.net_rx],['disk',st.pct],['dtemp',st.disk_temp]].forEach(([k,v])=>SPARK[k].push(v==null?0:v));
  if(TBUF.length>460){TBUF.shift();for(const k in SPARK)SPARK[k].shift();}
  updateSparks();pushOv(s);
  if(!$('#detail').classList.contains('hidden'))liveDetail();
  // header + chips
  $('#host').textContent=(nw.host||'nas')+'.local';
  $('#ip').textContent=nw.ip&&nw.ip!=='?'?nw.ip:'no network';
  const tc=$('#topchips');if(tc){const wc=nw.mode==='AP'?'warn':(nw.ip&&nw.ip!=='?'?'ok':'err');tc.innerHTML=chip(wc,nw.mode==='AP'?`Hotspot ${nw.ssid||''}`:`${nw.ssid||'no wifi'} ${nw.signal?nw.signal+'dB':''}`);}
  if($('#net-url'))$('#net-url').textContent=`http://${(nw.host||'nas')}.local:8090 · http://${nw.ip||'?'}:8090`;
  if(!$('#ambient').classList.contains('hidden'))updateAmbient();
  {const on=s.screen_on!==false,sb=s.bright;
   if(sb!=null&&!brDragging&&!ambientOn&&activeTab!=='photos'){br.value=sb;bv.textContent=sb+'%';}   // слайдер = реальная (не в ambient/photos)
   const nf=$('#night-from').value,nt=$('#night-to').value;
   $('#screen-sub').innerHTML=(on?`<span>${ic('i-sun')} ${sb!=null?sb:br.value}%</span>`:`<span class="lv-crit">${ic('i-moon')} off</span>`)+(nf&&nt?`<span>${ic('i-moon')} ${nf}–${nt}</span>`:'');}
  renderAlerts(s,st,sv,nw);
  // live-обновление только лёгких частей открытой страницы (без полного rebuild → нет дёрганья)
  if(!$('#page-power').classList.contains('hidden'))renderPower();
  updateBackupLive();}

function renderAlerts(s,st,sv,nw){const a=[];
  if(s.throttled_now)a.push(['crit','i-zap','Throttled']);
  if(s.temp>=82)a.push(['crit','i-thermo','CPU '+s.temp+'°C']);else if(s.temp>=72)a.push(['warn','i-thermo',s.temp+'°C']);
  if(st.mounted===false)a.push(['crit','i-disk','Storage disk NOT MOUNTED — backups disabled']);
  else if(st.readonly)a.push(['crit','i-disk','Disk READ-ONLY (ext4 error) — needs fsck/reboot']);
  else if(st.pct>=95)a.push(['crit','i-disk','Disk '+st.pct+'%']);else if(st.pct>=88)a.push(['warn','i-disk','Disk '+st.pct+'%']);
  if((nw.ip||'?')==='?')a.push(['warn','i-net','No network']);
  const nb=sv.nas_backup||{};if((nb.last_status||'')==='failed')a.push(['crit','i-cloud','Backup failed']);
  const has=a.length>0;
  $('#alerts').innerHTML=a.map(([c,i,t])=>`<span class="alert ${c}">${ic(i)}${t}</span>`).join('');
  // алерт занимает место нижнего графика (та же высота); плитки lastrow НЕ прячем
  $('#alerts').classList.toggle('hidden',!has);
  const ov=$('#ovchart-wrap');if(ov)ov.classList.toggle('hidden',has);}

/* SSE */
function connect(){const es=new EventSource('/api/stream');
  es.onmessage=e=>{try{render(JSON.parse(e.data));applyNight();}catch(_){}};
  es.onerror=()=>{es.close();setTimeout(connect,3000);};}

/* detail (graph + processes for cpu/mem) */
let dchart,dMetric='cpu',dRange='1h';
$$('#detail-ranges button').forEach(b=>b.onclick=()=>{$$('#detail-ranges button').forEach(x=>x.classList.remove('active'));b.classList.add('active');dRange=b.dataset.range;loadDetail();});
function openDetail(m){dMetric=m;$('#detail-title').textContent=MET[m].label;closePages();$('#detail').classList.remove('hidden');loadDetail();
  $('#detail-proc').innerHTML='';if(m==='cpu'||m==='mem')loadDetailProc(m);}
function yrange(m){const mx=MET[m].max||(m==='mem'?memTotal:null);return mx?{range:[0,mx]}:{range:(u,_,mx2)=>[0,mx2||1]};}
function makeDChart(data){const el=$('#dchart');el.innerHTML='';
  dchart=new uPlot({width:el.clientWidth||500,height:el.clientHeight||260,cursor:{show:false},legend:{show:false},
    scales:{x:{time:true},y:yrange(dMetric)},axes:[{stroke:'#8b949e',grid:{stroke:'#222b38'}},{stroke:'#8b949e',grid:{stroke:'#222b38'},size:44}],
    series:[{},{stroke:MET[dMetric].col,width:2,fill:MET[dMetric].col+'22',points:{show:false}}]},data||[[],[]],el);}
async function loadDetail(){makeDChart();if(dRange==='5m'){liveDetail();return;}
  try{const r=await(await fetch(`/api/history?m=${dMetric}&range=${dRange}`)).json();setDetail(r.t||[],r.v||[]);}catch(e){}}
function liveDetail(){if(dRange!=='5m'||!dchart)return;setDetail(TBUF.slice(),SPARK[dMetric].slice());}
function setDetail(t,v){if(dchart)dchart.setData([t,v]);const vv=v.filter(x=>x!=null);
  const cur=vv.length?vv[vv.length-1]:'–',mn=vv.length?Math.min(...vv).toFixed(1):'–',mx=vv.length?Math.max(...vv).toFixed(1):'–',av=vv.length?(vv.reduce((a,b)=>a+b,0)/vv.length).toFixed(1):'–';
  const s=last.system||{},nw=last.network||{},st=last.storage||{},R=(k,vl)=>`<div class="row"><span class="k">${k}</span><span>${vl}</span></div>`;
  let extra='';
  if(dMetric==='cpu')extra=R('Load avg (1/5/15m)',(s.load||[]).join(' / '))+R('Frequency',(s.freq_mhz||0)+' MHz')+R('Governor',s.governor||'?');
  else if(dMetric==='temp')extra=R('Throttled',s.throttled_now?'YES':'no')+R('Disk temp',st.disk_temp!=null?st.disk_temp+'°C':'—');
  else if(dMetric==='mem')extra=R('Used',(+s.mem_used).toFixed(1)+' GB')+R('Total',Math.round(s.mem_total)+' GB');
  else if(dMetric==='net_rx')extra=R('Download',fmtNet(s.net_rx))+R('Upload',fmtNet(s.net_tx))+R('IP',nw.ip||'?');
  else if(dMetric==='disk')extra=R('Used',TB(st.used))+R('Free',TB(st.avail))+R('Temp',(st.disk_temp||'?')+'°C');
  const stat=(n,l)=>`<div class="dstat"><div class="dn">${n}</div><div class="dl">${l}</div></div>`;
  $('#detail-info').innerHTML=`<div class="dstats">${stat(cur,'now')}${stat(mn,'min')}${stat(av,'avg')}${stat(mx,'max')}</div>${extra}`;}
async function loadDetailProc(m){try{const r=await(await fetch('/api/processes')).json();const isMem=m==='mem',rows=(isMem?r.mem:r.cpu)||[];
  $('#detail-proc').innerHTML=`<tr><th>Top processes</th><th>${isMem?'RAM':'CPU'}</th></tr>`
    +rows.map(p=>`<tr><td>${p.cmd}</td><td>${isMem?p.mem:p.cpu}%</td></tr>`).join('');}catch(e){}}
setInterval(()=>{if(!$('#detail').classList.contains('hidden')&&(dMetric==='cpu'||dMetric==='mem'))loadDetailProc(dMetric);},5000);

/* Docker (page) */
function renderProjects(){const pr=(last.services||{}).projects||[];
  $('#projects').innerHTML=pr.map(p=>{const ok=p.running===p.total&&p.total>0,sc=ok?'ok':p.running?'warn':'err';
    return `<div class="proj p-${sc}"><div class="top"><span class="name">${ic('i-box')} ${p.project}</span><span class="st"><span class="dot ${sc}"></span>${p.running}/${p.total}</span></div><div class="btns"><button class="start" data-p="${p.project}" data-a="start">${ic('i-play')}</button><button data-p="${p.project}" data-a="restart">${ic('i-restart')}</button><button class="stop" data-p="${p.project}" data-a="stop">${ic('i-stop')}</button></div></div>`;}).join('')||'<div class="note">no docker projects</div>';
  $$('#projects button').forEach(b=>b.onclick=async()=>{toast(b.dataset.a+' '+b.dataset.p+'…');await api('/api/docker',{project:b.dataset.p,action:b.dataset.a});
    setTimeout(()=>api('/api/snapshot').then(r=>r.json()).then(d=>{last=d;renderProjects();}),1800);});}

/* Apps tab: launcher of service UIs (tap → QR) */
async function renderApps(){try{const r=await(await fetch('/api/services')).json();
  $('#apps-grid').innerHTML=r.map((s,i)=>`<div class="appcard" data-i="${i}"><img class="appico" src="/api/appicon?u=${encodeURIComponent(s.url)}" onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><svg class="ic appico" style="display:none"><use href="#i-grid"/></svg><div class="an">${s.name}</div><div class="au">${s.url.replace('http://','')}</div></div>`).join('')||'<div class="note">no services (install docker stacks)</div>';
  $$('#apps-grid .appcard').forEach(el=>el.onclick=()=>{const s=r[el.dataset.i];openApp(s.name,s.url);});}catch(e){$('#apps-grid').innerHTML='error';}}
function openApp(name,url){$('#appframe-title').textContent=name;$('#appframe-iframe').src=url;
  $('#appframe-qr').onclick=()=>showQR(name,url);$('#appframe').classList.remove('hidden');}
$('#appframe-back').onclick=()=>{$('#appframe-iframe').src='about:blank';$('#appframe').classList.add('hidden');};
function showQR(name,url){$('#modal-title').textContent=name;const qr=qrcode(0,'M');qr.addData(url);qr.make();
  $('#modal-body').innerHTML=`<div style="background:#fff;padding:10px;border-radius:10px;display:inline-block">${qr.createSvgTag({cellSize:5,margin:1})}</div><div style="margin-top:10px;color:var(--mut);font-size:13px">${url}</div>`;
  $('#modal').classList.remove('hidden');}
async function renderServices(){try{const r=await(await fetch('/api/services')).json();
  $('#services-body').innerHTML=(r.length?'<div class="svc-list">'+r.map((s,i)=>`<div class="svc-item" data-i="${i}"><span>${ic('i-grid')} ${s.name}</span><span class="u">${s.url.replace('http://','')} · QR</span></div>`).join('')+'</div>':'<div class="note">no services</div>')+'<div class="note">Tap a service → QR code to open it on your phone.</div>';
  $$('#services-body .svc-item').forEach(el=>el.onclick=()=>{const s=r[el.dataset.i];showQR(s.name,s.url);});}catch(e){$('#services-body').innerHTML='error';}}

/* Disks */
function renderDisks(){const disks=(last.storage||{}).disks||[];
  $('#disks').innerHTML=disks.map(d=>{const parts=d.parts.filter(p=>p.mount).map(p=>{const cl=p.pct>=95?'crit':p.pct>=88?'high':p.pct>=75?'warn':'';
    return `<div class="part">${p.mount} · ${p.label||p.fstype||''} — ${TB(p.used)}/${TB(p.total)} (${p.pct??'?'}%)</div><div class="bar-fill"><i class="${cl}" style="width:${p.pct||0}%"></i></div>`;}).join('')||'<div class="part">not mounted</div>';
    const mounts=d.parts.map(p=>p.mount),role=mounts.includes('/')?'system':(mounts.includes('/mnt/storage')?'storage':'removable');
    const rl={system:'SYSTEM · microSD',storage:'STORAGE · main',removable:'REMOVABLE'}[role];
    return `<div class="disk"><div class="top"><div><div class="name">${d.name} <span style="color:var(--mut);font-weight:400;font-size:12px">${d.kind}</span></div><div class="meta">${d.model||''} ${TB(d.size)}${d.health&&d.health!='?'?' · '+d.health:''}</div></div><div style="text-align:right"><span class="badge ${role}">${rl}</span>${d.temp!=null?`<div class="temp">${d.temp}<small>°C</small></div>`:''}</div></div>${parts}</div>`;}).join('')||'<div>no disks</div>';}

/* Backups */
function bkbg(pct){return pct!=null?`background:linear-gradient(90deg,rgba(59,130,246,.28) ${pct}%,transparent ${pct}%)`:'';}
function renderBackupTiles(sv){const nb=sv.nas_backup||{},pr=sv.progress||{},ph=sv.photo||{},w=whichBackup(pr);
  const pt=$('#bk-photo'),nt=$('#bk-nas');
  $('#photo-v').textContent=w==='photo'?(pr.percent||0)+'%':(ph.files?ph.files+' files':'idle');
  $('#photo-sub').textContent=w==='photo'?`${pr.files_done||0}/${pr.files_total||'?'} files`:(ph.bytes?TB(ph.bytes)+(ph.last?' · '+ph.last:''):(ph.last?'last '+ph.last:'—'));
  pt.setAttribute('style',w==='photo'?bkbg(pr.percent):'');
  $('#nas-v').textContent=w==='nas'?(pr.percent||0)+'%':(nb.last_status||nb.status||'idle');
  const sched=sv.nas_sched&&sv.nas_sched!=='off'?sv.nas_sched:null;
  $('#nas-sub').textContent=w==='nas'?`${pr.speed||''} eta ${pr.eta||'?'}`:(sched?'auto '+sched:(nb.last_run?'last '+nb.last_run:'manual'));
  nt.setAttribute('style',w==='nas'?bkbg(pr.percent):'');
  $('#nas-dot').className='tdot '+(w==='nas'?'ok':((nb.last_status||'')==='failed'?'crit':(sched?'ok':'')));}
const bkCard=(icon,title,body)=>`<div class="bkcard">${icon}<div class="bkc"><div class="bkt">${title}</div>${body}</div></div>`;
const bkProg=pr=>`<div class="bkbar"><i id="bk-bar" style="width:${pr.percent||0}%"></i></div><div class="bks"><b id="bk-pct">${pr.percent||0}%</b> · <span id="bk-files">${pr.files_done||0}/${pr.files_total||'?'}</span> files · <span id="bk-speed">${pr.speed||'…'}</span> · eta <span id="bk-eta">${pr.eta||'?'}</span></div>`;
/* Photo import — карта SD/USB → /mnt/storage/usb-imports (авто при вставке). С удалением. */
function renderPhotoPage(){const sv=last.services||{},pr=sv.progress||{},ph=sv.photo||{},active=pr.active&&pr.kind==='photo';
  const big=`<div class="bigstat"><div><div class="n">${ph.files||0}</div><div class="l">files</div></div><div><div class="n">${ph.bytes?TB(ph.bytes):'—'}</div><div class="l">size</div></div></div>`;
  const body=active?bkProg(pr)+`<div class="bks">card: ${pr.label||'?'}</div>`
    :big+`<div class="bks">${ph.last?'last import '+ph.last+(ph.name?' · '+ph.name:''):'no imports yet'} · auto on card insert</div>`;
  $('#photo-body').innerHTML=bkCard(ic('i-camera'),'Copy photos from card to disk',body)
    +'<div class="h" style="margin-top:6px">Imports on disk <span id="imp-total" class="k"></span></div><div id="bk-cleanup" class="svc-list"></div>';
  loadCleanup();}
/* Auto-backup: сам баннер — тумблер (тап вкл/выкл, меняет стиль/контент). */
function renderSchedArea(sched){const on=sched&&sched!=='off';const sm=(sched||'').match(/^(daily|weekly) (\d\d:\d\d)/),fr=sm?sm[1]:'daily',tm=sm?sm[2]:'03:00';
  let h=`<div class="schedbanner toggle ${on?'on':'off'}" id="nas-sched-banner">${ic('i-clock')}<div class="sb"><div class="sbt">Auto-backup ${on?'ON':'OFF'}</div><div class="sbs">${on?sched:'tap to enable'}</div></div><span class="tgl ${on?'on':''}"></span></div>`;
  if(on){const[hh,mm]=tm.split(':');
    const hSel=`<select id="sch-h">${Array.from({length:24},(_,i)=>{const v=('0'+i).slice(-2);return `<option${v===hh?' selected':''}>${v}</option>`;}).join('')}</select>`;
    const mSel=`<select id="sch-m">${Array.from({length:12},(_,i)=>{const v=('0'+i*5).slice(-2);return `<option${v===mm?' selected':''}>${v}</option>`;}).join('')}</select>`;
    h+=`<div class="schedrow"><select id="sch-freq"><option value="daily">daily</option><option value="weekly">weekly (Sun)</option></select><span class="timepick">${hSel}<b>:</b>${mSel}</span><button class="cbtn run sm" id="sch-set">Update</button></div>`;}
  $('#sch-area').innerHTML=h;
  if($('#sch-freq'))$('#sch-freq').value=fr;
  $('#nas-sched-banner').onclick=()=>{if(on){doAction('nas-sched-off');renderSchedArea('off');toast('auto-backup OFF');}
    else{doAction('nas-sched-set',{freq:'daily',time:'03:00'});renderSchedArea('daily 03:00');toast('auto-backup ON · daily 03:00');}};
  const s=$('#sch-set');if(s)s.onclick=()=>{const f=$('#sch-freq').value,t=$('#sch-h').value+':'+$('#sch-m').value;doAction('nas-sched-set',{freq:f,time:t});renderSchedArea(f+' '+t);toast('updated · '+f+' '+t);};}
/* NAS backup — домашний NAS → /mnt/storage/nas-backup (rsync-модули). Без удаления. */
async function renderNasPage(){const sv=last.services||{},nb=sv.nas_backup||{},pr=sv.progress||{},active=pr.active&&pr.kind==='nas',sched=sv.nas_sched||'off';
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span class="ell">${v}</span></div>`;
  let conf={};try{conf=await(await fetch('/api/nas-conf')).json();}catch(e){}
  const cfg=conf.configured;
  // nas-backup-status.json = {updated, dest, disk:{}, modules:[{target,size,last_run,status}]}
  const mods=Array.isArray(nb.modules)?nb.modules:[];
  const byKey=k=>mods.find(e=>{const n=e.target||e.name||e.module||'';return n===k||n.endsWith('/'+k)||k.endsWith('/'+n);})||{};
  const folders=(conf.modules||[]).map(m=>{const[mod,fold]=m.split('|');const e=byKey(fold||mod);
    const dot=e.status?`<span class="dot ${e.status==='ok'?'ok':'crit'}"></span> `:'';
    return `<div class="svc-item"><span>${ic('i-box')} <span class="ell">${mod}</span></span><span class="u">${dot}${e.size?e.size+' ':''}→ ${fold||mod}</span></div>`;}).join('')
    ||`<div class="note">${cfg?'modules empty — add via Edit config (format: rsync-module/subpath|local_folder)':'not configured — tap "Edit config"'}</div>`;
  // карточка последнего бэкапа (когда + успех). last_run/status бывают null —
  // тогда сигнал о наличии копии берём из exists+size + времени проверки (updated).
  let last_run=0,anyFail=false,hasData=false,totSz=0;
  const szGB=s=>{const m=(s||'').match(/([\d.]+)\s*([KMGT])/i);if(!m)return 0;return +m[1]*{K:1e-6,M:1e-3,G:1,T:1e3}[m[2].toUpperCase()];};
  mods.forEach(e=>{if(e.last_run)last_run=Math.max(last_run,e.last_run);if(e.exists||e.last_run)hasData=true;if(e.status==='fail')anyFail=true;totSz+=szGB(e.size);});
  const rel=ts=>{if(!ts)return'';const d=(Date.now()/1000|0)-ts;return d<3600?Math.round(d/60)+' min ago':d<86400?Math.round(d/3600)+'h ago':Math.round(d/86400)+'d ago';};
  const when=last_run?rel(last_run):(nb.updated?'checked '+rel(nb.updated):'');
  const szTxt=totSz?(totSz>=1?totSz.toFixed(1)+' GB':(totSz*1000).toFixed(0)+' MB'):'';
  let lastCard;
  if(active)lastCard=`<div class="lastbk run">${ic('i-cloud')}<div><div class="lbt">Backing up… ${pr.percent||0}%</div><div class="lbs">${pr.speed||''} eta ${pr.eta||'?'}</div></div></div>`;
  else if(!hasData)lastCard=`<div class="lastbk none">${ic('i-cloud')}<div><div class="lbt">No backups yet</div><div class="lbs">press Run to start the first backup</div></div></div>`;
  else if(anyFail)lastCard=`<div class="lastbk fail">${ic('i-stop')}<div><div class="lbt">Last backup failed</div><div class="lbs">${when} — see Log</div></div></div>`;
  else lastCard=`<div class="lastbk ok">${ic('i-cloud')}<div><div class="lbt">Backed up ✓ ${szTxt}</div><div class="lbs">${when||'copy present'}</div></div></div>`;
  const progBlock=lastCard;
  const acts=active?`<button class="cbtn stop" id="bk-stop">${ic('i-stop')}Stop</button>`
    :`<button class="cbtn run" id="bk-run">${ic('i-cloud')}Run</button><button class="cbtn dry" id="bk-dry">${ic('i-list')}Dry-run</button><button class="cbtn diff" id="bk-diff">${ic('i-activity')}Diff</button>`;
  const panel=`<div class="naspanel">
    <div class="h">Auto-backup</div><div id="sch-area"></div>
    <div class="h" style="margin-top:8px">Connection</div>
    <div class="sideinfo">${R('Host',conf.host||'—')}${R('User',conf.user||'—')}${R('Dest',conf.dest||'—')}</div>
    <div class="nasbtns" style="margin-top:8px"><button class="minib" id="nas-editcfg" style="flex:1">${ic('i-list')}Edit config</button><button class="minib" id="nas-viewlog" style="flex:1">${ic('i-activity')}Log</button></div></div>`;
  const foldHdr=`<div class="foldhdr"><span>Backup folders</span>${nb.disk?`<span class="fhd">${nb.disk.used} / ${nb.disk.total} on disk</span>`:''}</div>`;
  $('#nas-body').innerHTML=`<div class="naslayout"><div class="nasmain">${progBlock}${foldHdr}<div class="svc-list">${folders}</div></div>${panel}</div>`;
  renderSchedArea(sched);
  $('#nas-viewlog').onclick=()=>showNasResult('Last NAS run');
  $('#nas-editcfg').onclick=()=>{$$('.page').forEach(p=>p.classList.add('hidden'));$('#page-configs').classList.remove('hidden');editConfig('nas-backup.conf');};
  $('#nas-acts').innerHTML=acts;   // Run/Dry/Diff/Stop — в шапке справа, возле заголовка
  const b=(id,act,msg)=>{const e=$('#'+id);if(e)e.onclick=()=>{doAction(act);toast(msg);};};
  b('bk-run','nas-backup','backup started');b('bk-stop','nas-stop','stopping');
  // dry/diff — детачатся, вывод в журнал → авто-открываем лог с результатом
  const bLog=(id,act,t)=>{const e=$('#'+id);if(e)e.onclick=()=>{doAction(act);toast(t+' running…');setTimeout(()=>showNasResult(t+' result'),3200);};};
  bLog('bk-dry','nas-dry','Dry-run');bLog('bk-diff','nas-diff','Diff');}
function updateBackupLive(){const pr=(last.services||{}).progress||{};
  const open=!$('#page-photo').classList.contains('hidden')?'photo':(!$('#page-nas').classList.contains('hidden')?'nas':null);
  if(!open)return;const wantActive=!!(pr.active&&pr.kind===open);
  if(wantActive!==!!$('#bk-bar')){open==='photo'?renderPhotoPage():renderNasPage();return;}  // структура сменилась
  if(wantActive){const set=(id,v)=>{const e=$('#'+id);if(e)e.textContent=v;};const bar=$('#bk-bar');if(bar)bar.style.width=(pr.percent||0)+'%';
    set('bk-pct',(pr.percent||0)+'%');set('bk-files',(pr.files_done||0)+'/'+(pr.files_total||'?'));set('bk-speed',pr.speed||'…');set('bk-eta',pr.eta||'?');}}

/* Disk page — SMART + ёмкость (вместо бесполезного графика заполненности) */
async function renderDiskPage(){const st=last.storage||{},pct=st.pct||0,cl=pct>=95?'crit':pct>=88?'high':pct>=75?'warn':'';
  const pill=(n,l)=>`<div class="pill"><div class="pn">${n}</div><div class="pl">${l}</div></div>`;
  $('#disk-page').innerHTML=`<div class="bkbar big"><i class="${cl}" style="width:${pct}%"></i></div>
    <div class="bks">${(st.used/1e12).toFixed(2)} / ${(st.size/1e12).toFixed(2)} TB · ${pct}% · ${TB(st.avail)} free</div>
    <div id="smart-pills" class="pills" style="margin-top:14px"><div class="note">loading SMART…</div></div>
    <div class="sideinfo" id="smart-info"></div>`;
  try{const s=await(await fetch('/api/smart')).json();const P=[];
    const poh=s.power_on_hours?parseInt(s.power_on_hours.replace(/,/g,'')):0;
    if(s.health)P.push(pill(s.health,'status'));
    if(s.temp)P.push(pill(s.temp+'°','temp'));
    if(poh)P.push(pill(poh>=48?Math.round(poh/24)+' d':poh+' h','powered on'));
    if(s.power_cycles)P.push(pill(s.power_cycles,'cycles'));
    if(s.wear)P.push(pill(s.wear,'wear used'));if(s.spare)P.push(pill(s.spare,'spare'));if(s.realloc)P.push(pill(s.realloc,'realloc'));
    $('#smart-pills').innerHTML=P.join('')||'<div class="note">SMART n/a (microSD)</div>';
    const now=new Date(),upd=now.toLocaleDateString('en-US',{month:'long',day:'2-digit',year:'numeric'})+' · '+('0'+now.getHours()).slice(-2)+':'+('0'+now.getMinutes()).slice(-2);
    const R=(k,v)=>v?`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`:'';
    $('#smart-info').innerHTML=R('Model',s.model)+R('Device',s.device)+R('Capacity',s.capacity)+R('Last updated',upd);
  }catch(e){$('#smart-pills').innerHTML='<div class="note">SMART error</div>';}}
async function loadCleanup(){try{const r=await(await fetch('/api/imports')).json();
  $('#imp-total').textContent='· '+TB(r.total);
  $('#bk-cleanup').innerHTML=r.items.map(i=>`<div class="svc-item"><span>${i.name} · ${TB(i.size)}</span><button class="del" data-n="${i.name}">${ic('i-stop')}Delete</button></div>`).join('')||'<div class="note">empty</div>';
  $$('#bk-cleanup .del').forEach(b=>b.onclick=()=>openModal('Delete '+b.dataset.n+'?',[['Delete','__del:'+b.dataset.n,1]]));}catch(e){}}
async function delImport(name){await api('/api/imports/delete',{name});toast('deleted');loadCleanup();}

/* YT page */
function renderYT(){const yt=(last.services||{}).yt||{},tog=$('#yt-toggle'),B=`http://${location.hostname}:8081`;
  if(!Object.keys(yt).length){$('#yt-status').innerHTML='<div class="note">YT-Archiver offline.</div>';['yt-stats','yt-queue','yt-recent','yt-channels'].forEach(i=>{const e=$('#'+i);if(e)e.innerHTML='';});tog.style.display='none';return;}
  // компактный статус-стрип
  let st;
  if(yt.downloading>0)st=`<div class="ytstrip dl">${ic('i-dl')}<b>Downloading ${yt.downloading}</b> · ${yt.pending||0} queued${yt.error?' · '+yt.error+' err':''}</div>`;
  else if(yt.paused)st=`<div class="ytstrip warn">${ic('i-stop')}Paused · ${yt.pending||0} pending</div>`;
  else st=`<div class="ytstrip ok">${ic('i-video')}Up to date · ${yt.pending||0} pending${yt.error?' · '+yt.error+' err':''}</div>`;
  $('#yt-status').innerHTML=st;
  tog.style.display='';tog.className='cbtn '+(yt.paused?'run':'diff');tog.innerHTML=yt.paused?ic('i-play')+'Resume all':ic('i-pause')+'Pause all';
  tog.onclick=async()=>{const np=!yt.paused;api('/api/yt',{action:np?'pause':'resume'});
    yt.paused=np;if(last.services&&last.services.yt)last.services.yt.paused=np;   // оптимистично — снапшот кэшируется ~30с
    toast(np?'paused':'resumed');renderYT();};
  const J=p=>fetch(B+p).then(r=>r.json()).catch(()=>null);
  const szu=b=>{const p=TB(b).split(' ');return p[0]+`<span class="u2"> ${p[1]||''}</span>`;};
  const sp=(n,l)=>`<div class="sgp"><div class="sgn">${n}</div><div class="sgl">${l}</div></div>`;
  const grp=(label,cls,inner)=>`<div class="statgroup ${cls}"><div class="sglabel">${label}</div><div class="sgrow">${inner}</div></div>`;
  Promise.all([J('/api/music/stats'),J('/api/storage/largest-channels'),J('/api/queue'),J('/api/videos'),J('/api/manual/count')]).then(([mus,large,queue,vids,man])=>{
    const V=Array.isArray(vids)?vids.filter(x=>!(x.is_music||x.is_music_via_playlist)):[];
    const vBytes=V.reduce((a,x)=>a+(x.file_size_bytes||0),0);
    const mT=(mus&&mus.tracks)||0,mB=(mus&&mus.total_bytes)||0;
    $('#yt-stats').innerHTML=
      grp('OVERALL','g-all',sp(V.length+mT,'items')+sp(szu(vBytes+mB),'size')+sp(yt.channels||0,'channels')+(man&&man.count?sp(man.count,'manual'):''))
     +grp('VIDEO','g-vid',sp(V.length||(yt.videos||0),'videos')+sp(szu(vBytes||((yt.total_bytes||0)-mB)),'size'))
     +grp('MUSIC','g-mus',sp(mT,'tracks')+sp((mus&&mus.playlists)||0,'playlists')+sp(szu(mB),'size'));
    const Q=Array.isArray(queue)?queue:[];
    $('#yt-queue').innerHTML=Q.length?Q.slice(0,12).map(x=>{const dl=(x.status||'').toLowerCase()==='downloading',p=x.progress!=null?Math.round(x.progress):null;
      return `<div class="svc-item ${dl?'online':''}"><span>${ic('i-video')} ${(x.title||'').slice(0,34)}</span><span class="u">${dl?(p!=null?p+'%':'↓'):(x.status||'queued')}</span></div>`;}).join(''):'<div class="note">queue empty</div>';
    const L=Array.isArray(large)?large:[],mx=Math.max(1,...L.map(c=>c.total_bytes||0));
    $('#yt-chn').textContent=L.length?'· '+(yt.channels||0)+' total':'';
    $('#yt-channels').innerHTML=L.slice(0,8).map(c=>`<div class="chrow"><div class="chtop"><span class="ell">${(c.name||'').slice(0,26)}</span><span class="u">${TB(c.total_bytes)} · ${c.video_count||0}v</span></div><div class="bar-fill"><i style="width:${Math.round((c.total_bytes||0)/mx*100)}%"></i></div></div>`).join('')||'<div class="note">no data</div>';
    const v=Array.isArray(vids)?vids:[],rec=v.filter(x=>x.downloaded_at).sort((a,b)=>(b.downloaded_at||'').localeCompare(a.downloaded_at||'')).slice(0,10);
    $('#yt-recent').innerHTML=(rec.length?rec:v.slice(0,10)).map(x=>`<div class="svc-item"><span>${ic((x.is_music||x.is_music_via_playlist)?'i-music':'i-video')} ${(x.title||'').slice(0,30)}</span><span class="u">${x.file_size_bytes?TB(x.file_size_bytes):''}</span></div>`).join('')||'<div class="note">empty</div>';
  });}

/* Power */
const MODEDESC={auto:'Auto — system picks governor by temp/throttle.',normal:'Normal — ondemand, up to max clock.',saver:'Saver — powersave, min clock.'};
function renderPower(){const s=last.system||{},pm=s.pmode||'auto';
  $$('#powermode button').forEach(b=>b.classList.toggle('active',b.dataset.mode===pm));
  $('#mode-desc').textContent=MODEDESC[pm]||'';
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  $('#power-info').innerHTML=R('mode',pm)+R('governor',s.governor||'?')+R('frequency',(s.freq_mhz||0)+' MHz')+R('CPU temp',(s.temp??'?')+'°C')+R('throttled',s.throttled_now?'YES':'no')+R('load',(s.load||[]).join(' '));}
$$('#powermode button').forEach(b=>b.onclick=()=>{doAction('power-mode',{mode:b.dataset.mode});setTimeout(renderPower,800);});
$$('#boost-seg button').forEach(b=>b.onclick=()=>{doAction('cpu-boost',{min:+b.dataset.min});toast('CPU boost '+b.dataset.min+'m');});

/* Network — блоки: Connection / Tailscale-тумблер / Hotspot / actions / WiFi / TS-devices */
function renderNetwork(){const nw=last.network||{},R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;
  const ap=nw.mode==='AP',sig=nw.signal,q=sig!=null?Math.max(0,Math.min(100,2*(sig+100))):null,tsOn=nw.ts_up;
  let h='<div class="h">Connection</div><div class="sideinfo">'
    +R('Network',ap?'Hotspot':(nw.ssid||'—'))
    +R('Signal',q!=null?`${q}% <span style="color:var(--mut)">(${sig} dBm)</span>`:'—')
    +R('IP',(nw.ip&&nw.ip!=='?')?nw.ip:'<span style="color:var(--crit)">no network</span>')
    +R('Hostname',(nw.host||'nas')+'.local')+R('Mode',ap?'Access Point':'Client')+'</div>';
  h+=`<div class="h" style="margin-top:12px">Tailscale VPN</div>
    <div class="schedbanner toggle ${tsOn?'on':'off'}" id="ts-banner">${ic('i-net')}<div class="sb"><div class="sbt">Tailscale ${tsOn?'ON':'OFF'}</div><div class="sbs">${tsOn?((nw.tailscale||'')+' · '+(nw.ts_peers||0)+' peers · tap to disconnect'):'tap to connect'}</div></div><span class="tgl ${tsOn?'on':''}"></span></div>`;
  if(nw.ap_ssid)h+=`<div class="h" style="margin-top:12px">Field hotspot</div><div class="aphot"><div class="apcol"><div class="k">SSID</div><div class="apv">${nw.ap_ssid}</div></div><div class="apcol"><div class="k">Password</div><div class="apv">${nw.ap_pass||'open'}</div></div></div>`;
  h+=`<div class="nasbtns" style="margin-top:12px"><button class="cbtn dry" id="wifi-reconnect">${ic('i-restart')}Reconnect</button><button class="cbtn diff" id="force-ap">${ic('i-net')}Force AP</button></div>`;
  h+=`<div class="h" style="margin-top:12px">WiFi networks <button id="wifi-scan" class="rbtn" style="float:right">${ic('i-restart')}</button></div><div id="wifi-list" class="svc-list"></div>`;
  h+=`<div class="h" style="margin-top:12px">Tailscale devices</div><div id="ts-list" class="svc-list"></div>`;
  $('#net-body').innerHTML=h;
  $('#ts-banner').onclick=()=>{doAction(tsOn?'tailscale-down':'tailscale-up');toast(tsOn?'Tailscale OFF':'Tailscale ON…');setTimeout(()=>api('/api/snapshot').then(r=>r.json()).then(d=>{last=d;renderNetwork();}),1800);};
  $('#wifi-reconnect').onclick=()=>{doAction('wifi-reconnect');toast('reconnecting WiFi');};
  $('#force-ap').onclick=()=>openModal('Force hotspot',[['Drop WiFi → start AP','force-ap',1]]);
  $('#wifi-scan').onclick=loadWifi;
  loadTsList();}
async function loadTsList(){try{const d=await(await fetch('/api/tailscale')).json();
  $('#ts-list').innerHTML=d.peers.map(p=>`<div class="svc-item ${p.online?'online':'offline'}" data-ip="${p.ip}"><span>${p.name} <span style="color:var(--mut);font-size:11px">${p.os}</span></span><span class="u">${p.online?'online':'offline'} · ${p.ip}</span></div>`).join('')||'<div class="note">no peers</div>';
  $$('#ts-list .svc-item').forEach(el=>el.onclick=async()=>{toast('ping '+el.dataset.ip+'…');const r=await(await api('/api/ts-ping',{ip:el.dataset.ip})).json();toast((r.out||'no reply').split('\n').pop());});}catch(e){}}
async function loadWifi(){$('#wifi-list').innerHTML='<div class="note">scanning…</div>';
  try{const n=await(await fetch('/api/wifi/scan')).json();
  $('#wifi-list').innerHTML=n.map(w=>`<div class="svc-item" data-ssid="${w.ssid}" data-sec="${w.sec}"><span>${w.active?'● ':''}${w.ssid}</span><span class="u">${w.signal}%${w.sec&&w.sec!=='--'?'':''}</span></div>`).join('')||'<div class="note">none</div>';
  $$('#wifi-list .svc-item').forEach(el=>el.onclick=()=>connectWifi(el.dataset.ssid,el.dataset.sec));}catch(e){$('#wifi-list').innerHTML='error';}}
function connectWifi(ssid,sec){if(sec&&sec!=='--'&&sec!==''){
    $('#wifi-list').innerHTML=`<div class="h">${ssid}</div><input id="wifi-pw" class="lfilter" type="password" placeholder="password" style="max-width:100%"><div style="display:flex;gap:8px;margin-top:8px"><button id="wifi-go" class="wide">Connect</button><button id="wifi-cancel" class="wide">Cancel</button></div>`;
    $('#wifi-go').onclick=()=>{doAction('wifi-connect',{ssid,password:$('#wifi-pw').value});toast('connecting '+ssid);};$('#wifi-cancel').onclick=loadWifi;
  }else{doAction('wifi-connect',{ssid});toast('connecting '+ssid);}}

/* Today + recent */
async function renderToday(){try{const d=await(await fetch('/api/today')).json();
  const R=(k,v)=>`<div class="row"><span class="k">${k}</span><span>${v}</span></div>`;let h='';
  if(d.date)h+=R('Date',d.date);if(d.uptime)h+=R('Uptime',d.uptime);
  if(d.cpu_temp!=null)h+=R('CPU temp',d.cpu_temp+'°C');
  if(d.ip)h+=R('IP',d.ip);if(d.ssid)h+=R('WiFi',d.ssid);
  if(d.storage)h+=R('Storage',`${d.storage.used} / ${d.storage.total} (${d.storage.pct}%)`+(d.storage.temp!=null?` · ${d.storage.temp}°C`:''));
  if(d.throttle)h+=R('Throttle',d.throttle.now?'NOW':(d.throttle.past?'past':'no'));
  if(d.photo_today)h+=R('Photo today',`${d.photo_today.cards} cards · ${d.photo_today.files} files · ${d.photo_today.size}`);
  h+=R('NAS today',d.nas_today?(typeof d.nas_today==='object'?(d.nas_today.status||'done'):d.nas_today):'—');
  if(d.errors_today!=null)h+=R('Errors',d.errors_today);if(d.incomplete!=null)h+=R('Incomplete',d.incomplete);
  $('#today-body').innerHTML=h||'<div class="note">No summary yet (daily 21:00).</div>';
  const ev=Array.isArray(d.events)?d.events:[];
  $('#today-events').innerHTML=ev.length?ev.slice().reverse().map(e=>`<div class="svc-item"><span>${e}</span></div>`).join(''):'<div class="note">no events</div>';
  }catch(e){$('#today-body').innerHTML='error';}loadRecent();}
async function loadRecent(){try{const d=await(await fetch('/api/recent')).json();
  $('#recent-list').innerHTML=d.count?d.items.map(i=>`<div class="svc-item"><span>${i.path}</span><span class="u">${(i.size/1e6).toFixed(1)} MB</span></div>`).join(''):'<div class="note">nothing new in 24h</div>';}catch(e){}}

/* Failed units */
async function renderFailed(){try{const u=await(await fetch('/api/failed')).json();
  $('#failed-body').innerHTML=u.length?'<div class="svc-list">'+u.map(n=>`<div class="svc-item"><span>${n}</span><button class="minib" data-u="${n}">Restart</button></div>`).join('')+'</div>':'<div class="note">No failed units</div>';
  $$('#failed-body .minib').forEach(b=>b.onclick=()=>{doAction('restart-unit',{unit:b.dataset.u});toast('restart '+b.dataset.u);setTimeout(renderFailed,1500);});}catch(e){$('#failed-body').innerHTML='error';}}

/* Configs */
async function renderConfigs(){try{const r=await(await fetch('/api/configs')).json();
  $('#configs-body').innerHTML='<div class="svc-list">'+r.map(c=>`<div class="svc-item" data-n="${c.name}"><span>${c.name}${c.desc?' — <span style="color:var(--mut)">'+c.desc+'</span>':''}</span><span class="u">edit</span></div>`).join('')+'</div><div class="note">Tap to edit. Some contain passwords/tokens.</div>';
  $$('#configs-body .svc-item').forEach(el=>el.onclick=()=>editConfig(el.dataset.n));}catch(e){$('#configs-body').innerHTML='error';}}
async function editConfig(name){try{const r=await(await fetch('/api/config?name='+encodeURIComponent(name))).json();const esc=(r.content||'').replace(/&/g,'&amp;').replace(/</g,'&lt;');
  $('#configs-body').innerHTML=`<div class="edbar"><span class="ell" style="flex:1">${name}</span><button class="cbtn dry sm" id="cfg-back">${ic('i-back')}Back</button><button class="cbtn run sm" id="cfg-save">Save</button></div><textarea id="cfg-edit" class="editor">${esc}</textarea>`;
  $('#cfg-save').onclick=async()=>{const x=await(await api('/api/config',{name,content:$('#cfg-edit').value})).json();toast(x.ok?'saved ✓':'error: '+(x.err||x.error||''));};
  $('#cfg-back').onclick=renderConfigs;}catch(e){toast('error');}}

/* Logs */
let logsRaw='';
async function loadLogs(){$('#logs-body').textContent='loading…';try{logsRaw=await(await fetch('/api/logs')).text();renderLogs();const b=$('#logs-body');b.scrollTop=b.scrollHeight;}catch(e){$('#logs-body').textContent='error';}}
function renderLogs(){const q=($('#logs-filter').value||'').toLowerCase(),esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;');
  $('#logs-body').innerHTML=logsRaw.split('\n').filter(l=>!q||l.toLowerCase().includes(q)).map(l=>{const lc=l.toLowerCase(),c=/(error|fail|critical|\berr\b)/.test(lc)?'log-err':/warn/.test(lc)?'log-warn':'';return c?`<span class="${c}">${esc(l)}</span>`:esc(l);}).join('\n');}
$('#logs-refresh').onclick=loadLogs;$('#logs-filter').oninput=renderLogs;

/* update page */
let updTimer=null;
$('#update-run').onclick=async()=>{$('#update-body').textContent='Starting…';await api('/api/update/run',{});
  clearInterval(updTimer);updTimer=setInterval(async()=>{try{$('#update-body').textContent=await(await fetch('/api/update/log')).text();const b=$('#update-body');b.scrollTop=b.scrollHeight;}catch(e){}},1500);};

/* actions / modal */
$('#btn-power').onclick=()=>openModal('Power',[['Reboot','reboot',1],['Shut down','poweroff',1]]);
function openModal(title,btns){$('#modal-title').textContent=title;$('#modal-body').innerHTML='';
  btns.forEach(([l,a,dg])=>{const b=document.createElement('button');b.textContent=l;if(dg)b.className='danger';b.onclick=()=>{closeModal();doAction(a);};$('#modal-body').appendChild(b);});
  $('#modal').classList.remove('hidden');}
const closeModal=()=>$('#modal').classList.add('hidden');
$('#modal-cancel').onclick=closeModal;
async function doAction(name,body){if(name.startsWith('__del:'))return delImport(name.slice(6));
  toast('…');try{const r=await(await api('/api/action/'+name,body||{})).json();toast(r.ok||r.detached?'OK':('Error: '+(r.err||r.error||'')));}catch(e){toast('Network error');}}
$('#btn-exit').onclick=()=>doAction('screen',{exit_kiosk:true});
$('#diag-run').onclick=async()=>{toast('building diag…');try{const r=await(await api('/api/diag',{})).json();toast(r.ok?(r.sent?'sent to Telegram':'saved: '+r.path):'error: '+(r.error||''));}catch(e){toast('error');}};
/* log files viewer (#3) + nas-run log (#4) */
async function renderLogfiles(){$('#page-logfiles .back').onclick=closePages;try{const r=await(await fetch('/api/logfiles')).json();
  $('#lf-body').innerHTML='<div class="svc-list">'+r.map(f=>`<div class="svc-item" data-n="${f.name}"><span>${f.name}</span><span class="u">${(f.size/1024).toFixed(0)} KB</span></div>`).join('')+'</div>'+(r.length?'':'<div class="note">no log files</div>');
  $$('#lf-body .svc-item').forEach(el=>el.onclick=()=>openLogfile(el.dataset.n,el.dataset.n));}catch(e){$('#lf-body').innerHTML='error';}}
async function openLogfile(name,title){openPage('page-logfiles');
  $('#lf-body').innerHTML=`<button class="minib" id="lf-back">← files</button><div class="h" style="margin-top:6px">${title}</div><pre class="scrollbox" id="lf-view" style="font:11px/1.4 ui-monospace,monospace;color:var(--mut);white-space:pre-wrap;max-height:300px">loading…</pre>`;
  $('#lf-back').onclick=renderLogfiles;dragScroll($('#lf-view'));
  try{const url=name==='__nas__'?'/api/naslog':'/api/logfile?name='+encodeURIComponent(name);const t=await(await fetch(url)).text();$('#lf-view').textContent=t||'(empty)';const v=$('#lf-view');v.scrollTop=v.scrollHeight;}catch(e){$('#lf-view').textContent='error';}}
$('#logfiles-btn').onclick=()=>{openPage('page-logfiles');renderLogfiles();};
/* NAS dry/diff/run — парсим rsync-статистику в понятную сводку (не сырой лог) */
async function showNasResult(title){openPage('page-logfiles');
  $('#page-logfiles .back').onclick=()=>openPage('page-nas');   // back → обратно на NAS, не на главную
  $('#lf-body').innerHTML=`<div class="h">${title}</div><div class="note" style="margin:0 0 10px">Dry-run = preview (nothing is copied). Diff = which files differ.</div><div id="nas-res">running…</div>`;
  try{let raw=(await(await fetch('/api/naslog')).text()).replace(/\x1b\[[0-9;]*m/g,'');
    // только ПОСЛЕДНИЙ запуск (журнал хранит и старые провальные)
    const seg=raw.split(/Started nas-backup-runtime/);let t=seg.length>1?seg[seg.length-1]:raw;
    const num=re=>{const m=t.match(re);return m?parseInt(m[1].replace(/[, ]/g,'')):null;};
    const sz=re=>{const m=t.match(re);return m?m[1].trim():null;};
    const files=num(/Number of files:\s*([\d,]+)/), copy=num(/regular files transferred:\s*([\d,]+)/);
    const del=num(/deleted files:\s*([\d,]+)/), created=num(/created files:\s*([\d,]+)/);
    const total=sz(/Total file size:\s*([\d.,]+\s*\S*)/), failed=/rsync error|\[ERR\]|\bfailed\b/i.test(t);
    // itemized изменения (diff): строки rsync --itemize-changes
    const changes=t.split('\n').map(l=>l.trim()).filter(l=>/^([<>ch.*][fdLDS][.+cstpoguaxn?]+\s)|^\*deleting\s/.test(l)).slice(0,60);
    const pill=(n,l,c)=>`<div class="pill"${c?` style="border-color:${c}66"`:''}><div class="pn"${c?` style="color:${c}"`:''}>${n==null?'–':n}</div><div class="pl">${l}</div></div>`;
    let banner;
    if(failed)banner=`<div class="lastbk fail">${ic('i-stop')}<div><div class="lbt">Failed</div><div class="lbs">see Log — rsync error</div></div></div>`;
    else if((copy||0)===0&&(del||0)===0&&(created||0)===0)banner=`<div class="lastbk ok">${ic('i-cloud')}<div><div class="lbt">In sync ✓</div><div class="lbs">copy matches NAS, nothing to copy</div></div></div>`;
    else banner=`<div class="lastbk run">${ic('i-dl')}<div><div class="lbt">${copy||0} files to copy${del?' · '+del+' to delete':''}</div><div class="lbs">Run will do it</div></div></div>`;
    let h=banner+`<div class="pills" style="margin-top:10px">${pill(files,'files total','#3b82f6')}${pill(copy,'to copy',copy?'#3fb950':null)}${pill(del,'to delete',del?'#f85149':null)}${pill(total,'size','#22d3ee')}</div>`;
    if(changes.length)h+=`<div class="h" style="margin-top:6px">Changed files (${changes.length})</div><div class="svc-list">`+changes.map(l=>`<div class="svc-item"><span class="ell">${l.replace(/&/g,'&amp;').replace(/</g,'&lt;')}</span></div>`).join('')+`</div>`;
    $('#nas-res').innerHTML=h;
  }catch(e){$('#nas-res').innerHTML='<div class="note">error reading result</div>';}}
/* Pi config backup (#1) */
async function loadPiBackup(){try{const d=await(await fetch('/api/pibackup')).json();
  $('#pibk-info').textContent=d.count?`${d.count} · last ${d.when}`:'none yet';}catch(e){}}
$('#pibk-run').onclick=()=>{doAction('pi-backup');toast('pi config backup started');setTimeout(loadPiBackup,4000);};

/* screen */
const LS=localStorage,br=$('#brightness'),bv=$('#brightness-val');let brDragging=false;
function setBrightness(v,save){bv.textContent=v+'%';api('/api/action/screen',{brightness:v+'%'});if(save)uiSet('brightness',v);}
br.value=LS.brightness||80;bv.textContent=br.value+'%';
br.addEventListener('pointerdown',()=>brDragging=true);
br.oninput=()=>{brDragging=true;setBrightness(br.value,true);};
['pointerup','pointercancel','change'].forEach(e=>br.addEventListener(e,()=>setTimeout(()=>brDragging=false,500)));
$('#screen-timeout').value=LS.screenTimeout||'300';$('#screen-timeout').onchange=e=>uiSet('screenTimeout',e.target.value);
{const im=$('#idle-mode');if(im){im.value=LS.idleMode||'ambient';im.onchange=e=>uiSet('idleMode',e.target.value);}}
{const nt=$('#night-timeout');if(nt){nt.value=LS.nightTimeout||'';nt.onchange=e=>uiSet('nightTimeout',e.target.value);}}
{const pt=$('#ph-thumb');if(pt){pt.value=LS.phThumb||'400';pt.onchange=e=>uiSet('phThumb',e.target.value);}}
{const pg=$('#ph-tg');if(pg){pg.value=LS.phTg||'0';pg.onchange=e=>uiSet('phTg',e.target.value);}}
['night-from','night-to','night-level'].forEach(id=>{const el=$('#'+id);if(LS[id])el.value=LS[id];el.onchange=()=>{uiSet(id,el.value);nightApplied=null;};});
$('#rotate-apply').onclick=()=>{const v=$('#rotate').value;if(v)doAction('screen',{rotate:v});};
let lastAct=Date.now(),screenOff=false,ambientOn=false;
let preAmbBright=80;
function ambientShow(){if(!ambientOn)preAmbBright=+br.value||80;ambientOn=true;updateAmbient();$('#ambient').classList.remove('hidden');api('/api/action/screen',{brightness:(+(localStorage.ambBright||30))+'%'});}
function ambientHide(){if(!ambientOn)return;ambientOn=false;$('#ambient').classList.add('hidden');lastAct=Date.now();api('/api/action/screen',{brightness:preAmbBright+'%'});br.value=preAmbBright;bv.textContent=preAmbBright+'%';}
const AMB_CATS=['Network','System','Storage','Services'];
const AMB_ITEMS=[
  {k:'wifi',cat:'Network',label:'WiFi',ic:'i-net'},{k:'ip',cat:'Network',label:'IP address',ic:'i-net'},
  {k:'signal',cat:'Network',label:'Signal',ic:'i-net'},{k:'ts',cat:'Network',label:'Tailscale',ic:'i-net'},
  {k:'temp',cat:'System',label:'CPU temp',ic:'i-thermo'},{k:'cpu',cat:'System',label:'CPU load',ic:'i-cpu'},
  {k:'ram',cat:'System',label:'RAM',ic:'i-ram'},{k:'power',cat:'System',label:'Power mode',ic:'i-zap'},
  {k:'freq',cat:'System',label:'CPU freq',ic:'i-cpu'},{k:'uptime',cat:'System',label:'Uptime',ic:'i-activity'},
  {k:'disk',cat:'Storage',label:'Disk used',ic:'i-disk'},{k:'dtemp',cat:'Storage',label:'Disk temp',ic:'i-thermo'},
  {k:'dfree',cat:'Storage',label:'Disk free',ic:'i-disk'},
  {k:'backup',cat:'Services',label:'NAS backup',ic:'i-cloud'},{k:'yt',cat:'Services',label:'YT queue',ic:'i-video'},
  {k:'docker',cat:'Services',label:'Docker',ic:'i-box'}];
const AMB_DEF='date,wifi,temp,disk,backup';
function ambShowSet(){return new Set((localStorage.amb_show??AMB_DEF).split(',').filter(Boolean));}
function ambVals(){const s=last.system||{},nw=last.network||{},sv=last.services||{},sg=last.storage||{},nb=sv.nas_backup||{},yt=sv.yt||{},proj=sv.projects||[];
  const sig=nw.signal,q=sig!=null?Math.max(0,Math.min(100,2*(sig+100))):null;
  const bk=nb.last_status==='ok'?'<span style="color:var(--ok)">OK</span>':(nb.last_status==='failed'?'<span style="color:var(--crit)">failed</span>':'—');
  return {wifi:nw.mode==='AP'?'Hotspot':(nw.ssid||'—'),ip:(nw.ip&&nw.ip!=='?')?nw.ip:'—',signal:q!=null?q+'%':'—',
    ts:nw.ts_up?'<span style="color:var(--ok)">on</span>':'off',temp:(s.temp??'?')+'°',cpu:(s.cpu??'?')+'%',
    ram:(s.mem_used??'?')+'%',power:s.pmode||'auto',freq:(s.freq_mhz||'?')+' MHz',uptime:fmtUp(s.uptime||0),
    disk:(sg.pct??'?')+'%',dtemp:sg.temp!=null?sg.temp+'°':'—',dfree:(sg.total&&sg.used)?TB(sg.total-sg.used):'—',
    backup:bk,yt:(yt.pending||0)+' queued',docker:proj.length?proj.reduce((a,p)=>a+p.running,0)+'/'+proj.reduce((a,p)=>a+p.total,0):'—'};}
function updateAmbient(){const d=new Date(),sh=ambShowSet(),V=ambVals();
  $('#amb-time').textContent=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);
  $('#amb-date').style.display=sh.has('date')?'':'none';
  $('#amb-date').textContent=d.toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long'});
  let cols='';
  AMB_CATS.forEach(cat=>{const items=AMB_ITEMS.filter(it=>it.cat===cat&&sh.has(it.k));if(!items.length)return;
    cols+=`<div class="ambcol"><div class="ambct">${cat}</div>`+items.map(it=>`<div class="ambrow">${ic(it.ic)}<span class="ambk">${it.label}</span><span class="ambv">${V[it.k]}</span></div>`).join('')+`</div>`;});
  $('#amb-stat').innerHTML=cols;}
function renderAmbientSettings(){const ab=$('#amb-bright');if(ab){ab.value=localStorage.ambBright||30;$('#amb-bright-val').textContent=ab.value+'%';
    ab.oninput=()=>$('#amb-bright-val').textContent=ab.value+'%';
    ab.onchange=()=>{uiSet('ambBright',ab.value);if(ambientOn)api('/api/action/screen',{brightness:ab.value+'%'});};}
  const sh=ambShowSet(),chip=(k,l)=>`<button class="evchip ${sh.has(k)?'':'off'}" data-k="${k}">${l}</button>`;
  let html=`<div class="ambset-cat">General</div><div class="evfilters">${chip('date','Date')}</div>`;
  AMB_CATS.forEach(cat=>{html+=`<div class="ambset-cat">${cat}</div><div class="evfilters">`+AMB_ITEMS.filter(i=>i.cat===cat).map(i=>chip(i.k,i.label)).join('')+`</div>`;});
  $('#amb-toggles').innerHTML=html;
  $$('#amb-toggles .evchip').forEach(b=>b.onclick=()=>{const s=ambShowSet(),k=b.dataset.k;s.has(k)?s.delete(k):s.add(k);uiSet('amb_show',[...s].join(','));renderAmbientSettings();if(ambientOn)updateAmbient();});
  $('#amb-preview').onclick=()=>ambientShow();}
['pointerdown','touchstart','keydown'].forEach(ev=>addEventListener(ev,()=>{
  if(ambientOn){ambientHide();return;}
  lastAct=Date.now();if(screenOff){screenOff=false;api('/api/action/screen',{backlight:'on'});setBrightness(br.value);}},{passive:true}));
$('#btn-ambient').onclick=()=>ambientShow();
const RING=2*Math.PI*16;
setInterval(()=>{if(ambientOn)updateAmbient();
  let to=+($('#screen-timeout').value||0);const nt=+(($('#night-timeout')||{}).value||0);if(nt&&inNightWindow())to=nt;
  const ring=$('#ring'),cd=$('#screen-cd');
  if(!to){cd.textContent='∞';ring.style.strokeDashoffset=0;return;}
  if(screenOff||ambientOn){cd.textContent=ambientOn?'◐':'zZ';ring.style.strokeDashoffset=RING;return;}
  const rem=Math.max(0,to-(Date.now()-lastAct)/1000);cd.textContent=rem>=60?Math.ceil(rem/60)+'m':Math.ceil(rem)+'s';
  ring.style.strokeDasharray=RING;ring.style.strokeDashoffset=RING*(1-rem/to);
  if(rem<=0){if((localStorage.idleMode||'ambient')==='off'){screenOff=true;api('/api/action/screen',{backlight:'off'});}else ambientShow();}},1000);
let nightApplied=null;
function inNightWindow(){const f=$('#night-from').value,t=$('#night-to').value;if(!f||!t)return false;
  const d=new Date(),cur=('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);
  return f<t?(cur>=f&&cur<t):(cur>=f||cur<t);}
function applyNight(){if(!$('#night-from').value||!$('#night-to').value)return;
  const target=inNightWindow()?+$('#night-level').value:+br.value;
  if(!screenOff&&!ambientOn&&target!==nightApplied){nightApplied=target;api('/api/action/screen',{brightness:target+'%'});}}

/* mini-graph period per metric */
const fmtPer=s=>({60:'1m',300:'5m',900:'15m',1800:'30m',3600:'1h',10800:'3h',21600:'6h',43200:'12h',86400:'24h'}[s]||((s/60|0)+'m'));
function updatePeriodLabels(){$$('.spkper').forEach(e=>e.textContent=fmtPer(sparkWin(e.dataset.m)));}
$$('select[data-sp]').forEach(s=>{const m=s.dataset.sp;s.value=localStorage['spark_'+m]||'300';
  s.onchange=()=>{uiSet('spark_'+m,s.value);fetchSparkHist(m);updateSparks();updatePeriodLabels();};
  if(+s.value>900)fetchSparkHist(m);});
updatePeriodLabels();
{const ovp=$('#ov-period');if(ovp){ovp.value=localStorage.ov_period||'3600';ovp.onchange=()=>{uiSet('ov_period',ovp.value);initOvChart();};}}

/* accent */
const ACCENTS=['#e8a87c','#d29922','#d9c47a','#f0883e','#f85149','#ec6cb9','#c264f0','#a371f7','#7c83f7','#3b82f6','#2196f3','#22d3ee','#2dd4bf','#3fb950','#56d364','#a5d64c','#f0506e','#b1bac4'];
const BGS=[
 {bg:'#0d1117',panel:'#161b22',p2:'#1c2128',line:'#30363d'},
 {bg:'#000000',panel:'#0d0d10',p2:'#17171c',line:'#28282f'},
 {bg:'#11141a',panel:'#1a1f27',p2:'#232a34',line:'#343d49'},
 {bg:'#15181d',panel:'#20242b',p2:'#2b313a',line:'#3c4450'},
 {bg:'#0a0f1f',panel:'#12182b',p2:'#1b2540',line:'#2d3c5e'},
 {bg:'#0e0c1a',panel:'#171328',p2:'#211c38',line:'#382e5a'},
 {bg:'#08151a',panel:'#0f2028',p2:'#172d36',line:'#28424c'},
 {bg:'#0a140f',panel:'#121e18',p2:'#1a2a21',line:'#2b4035'},
 {bg:'#140a16',panel:'#1e1424',p2:'#291c33',line:'#412e4e'},
 {bg:'#160a0e',panel:'#221319',p2:'#301d24',line:'#4a2e38'},
 {bg:'#15110b',panel:'#1f1a11',p2:'#2a2318',line:'#3e3424'}];
function applyAccent(c){document.documentElement.style.setProperty('--acc',c);localStorage.accent=c;
  $$('#accent .swatch').forEach(s=>s.classList.toggle('sel',s.dataset.c===c));}
function applyBg(i){const b=BGS[i];if(!b)return;const r=document.documentElement.style;
  r.setProperty('--bg',b.bg);r.setProperty('--panel',b.panel);r.setProperty('--panel2',b.p2);r.setProperty('--line',b.line);
  localStorage.bgTheme=i;$$('#bgsw .swatch').forEach(s=>s.classList.toggle('sel',+s.dataset.i===i));}
$('#accent').innerHTML=ACCENTS.map(c=>`<button class="swatch" data-c="${c}" style="background:${c}"></button>`).join('');
$('#bgsw').innerHTML=BGS.map((b,i)=>`<button class="swatch" data-i="${i}" style="background:linear-gradient(135deg,${b.panel} 50%,${b.p2} 50%);border-color:${b.line}"></button>`).join('');
$$('#accent .swatch').forEach(s=>s.onclick=()=>{applyAccent(s.dataset.c);uiSet('accent',s.dataset.c);});
$$('#bgsw .swatch').forEach(s=>s.onclick=()=>{applyBg(+s.dataset.i);uiSet('bgTheme',s.dataset.i);});
applyAccent(localStorage.accent||'#3b82f6');applyBg(localStorage.bgTheme!=null?+localStorage.bgTheme:0);

/* тач-клавиатура (squeekboard) по фокусу текстовых полей — Chromium сам не зовёт */
const KBSEL='input:not([type=range]):not([type=checkbox]):not([type=radio]):not([type=button]),textarea';
addEventListener('focusin',e=>{if(e.target&&e.target.matches&&e.target.matches(KBSEL))api('/api/action/osk',{show:true});});
addEventListener('focusout',e=>{if(e.target&&e.target.matches&&e.target.matches(KBSEL))setTimeout(()=>{const a=document.activeElement;if(!a||!a.matches(KBSEL))api('/api/action/osk',{show:false});},250);});

/* drag-scroll */
function dragScroll(el){let down=false,sy=0,stp=0,moved=false;
  el.addEventListener('pointerdown',e=>{if(e.target.closest('input,textarea,select'))return;down=true;sy=e.clientY;stp=el.scrollTop;moved=false;});
  el.addEventListener('pointermove',e=>{if(!down)return;const dy=e.clientY-sy;if(Math.abs(dy)>6)moved=true;if(moved)el.scrollTop=stp-dy;});
  const end=()=>down=false;['pointerup','pointercancel','pointerleave'].forEach(ev=>el.addEventListener(ev,end));
  el.addEventListener('click',e=>{if(moved){e.stopPropagation();e.preventDefault();}},true);}
['.tab','.pbody','.scrollbox','.sideinfo'].forEach(sel=>$$(sel).forEach(dragScroll));

connect();initOvChart();   /* яркость НЕ форсим на старте — слайдер синхронизируется с реальной */