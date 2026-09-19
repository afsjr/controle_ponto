(() => {
  'use strict';

  const STORAGE_KEY = 'ponto-claro-v1';
  const STANDARD_MINUTES = 8 * 60;
  const TOLERANCE_MINUTES = 30;
  const colors = [{bg:'#edf2ff',fg:'#5271c9'},{bg:'#f7edff',fg:'#9466c2'},{bg:'#fff1e8',fg:'#c87547'},{bg:'#e8f7f0',fg:'#3b9974'},{bg:'#fff5e3',fg:'#bf8a33'}];
  const seed = () => {
    const today = new Date(); const at = (hours, minutes) => { const d = new Date(today); d.setHours(hours, minutes, 0, 0); return d.toISOString(); };
    const workers = [
      {id:'w1',name:'Ana Beatriz Lima',role:'Design',code:'218406',active:true,createdAt:at(8,0)},
      {id:'w2',name:'Carlos Eduardo Souza',role:'Engenharia',code:'491827',active:true,createdAt:at(8,0)},
      {id:'w3',name:'Juliana Martins',role:'Produto',code:'735102',active:true,createdAt:at(8,0)},
      {id:'w4',name:'Rafael Oliveira',role:'Operações',code:'864319',active:true,createdAt:at(8,0)},
      {id:'w5',name:'Beatriz Almeida',role:'Marketing',code:'305671',active:true,createdAt:at(8,0)}
    ];
    const records = [
      {id:'r1',workerId:'w1',type:'in',timestamp:at(8,2),createdAt:at(8,2),createdBy:'Sistema'},
      {id:'r2',workerId:'w1',type:'out',timestamp:at(12,5),createdAt:at(12,5),createdBy:'Sistema'},
      {id:'r3',workerId:'w1',type:'in',timestamp:at(13,1),createdAt:at(13,1),createdBy:'Sistema'},
      {id:'r4',workerId:'w2',type:'in',timestamp:at(7,54),createdAt:at(7,54),createdBy:'Sistema'},
      {id:'r5',workerId:'w2',type:'out',timestamp:at(17,2),createdAt:at(17,2),createdBy:'Sistema'},
      {id:'r6',workerId:'w3',type:'in',timestamp:at(9,18),createdAt:at(9,18),createdBy:'Sistema'},
      {id:'r7',workerId:'w4',type:'in',timestamp:at(8,12),createdAt:at(8,12),createdBy:'Sistema'},
      {id:'r8',workerId:'w4',type:'out',timestamp:at(12,0),createdAt:at(12,0),createdBy:'Sistema'},
      {id:'r9',workerId:'w4',type:'in',timestamp:at(13,0),createdAt:at(13,0),createdBy:'Sistema'},
      {id:'r10',workerId:'w5',type:'in',timestamp:at(8,46),createdAt:at(8,46),createdBy:'Sistema'}
    ];
    return {workers,records,corrections:[]};
  };
  let state = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null') || seed();
  const save = () => localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  if (!state.workers.some(w => w.code === '999999')) { state.workers.push({id:'w-test',name:'Teste Terminal',role:'Ambiente de teste',code:'999999',active:true,createdAt:new Date().toISOString()}); save(); }
  const qs = (s) => document.querySelector(s);
  const qsa = (s) => [...document.querySelectorAll(s)];
  const worker = id => state.workers.find(w => w.id === id);
  const initials = name => name.split(' ').slice(0,2).map(x => x[0]).join('').toUpperCase();
  const fmtTime = iso => new Date(iso).toLocaleTimeString('pt-BR',{hour:'2-digit',minute:'2-digit'});
  const fmtDate = iso => new Date(iso).toLocaleDateString('pt-BR',{day:'2-digit',month:'2-digit',year:'numeric'});
  const todayKey = () => new Date().toISOString().slice(0,10);
  const isToday = iso => new Date(iso).toISOString().slice(0,10) === todayKey();
  const effective = record => { const c = state.corrections.find(x => x.recordId === record.id); return c ? {...record,type:c.type,timestamp:c.timestamp,corrected:true,correction:c} : record; };
  const recordsFor = (id, todayOnly = false) => state.records.filter(r => r.workerId === id && (!todayOnly || isToday(effective(r).timestamp))).map(effective).sort((a,b) => new Date(a.timestamp)-new Date(b.timestamp));
  const minutesWorked = id => { const rs = recordsFor(id,true); let total=0, open=null; rs.forEach(r => { if(r.type==='in') open = r.timestamp; else if(open){ total += (new Date(r.timestamp)-new Date(open))/60000; open=null; } }); if(open) total += Math.max(0,(Date.now()-new Date(open))/60000); return Math.round(total); };
  const isClockedIn = id => { const rs=recordsFor(id,true); return rs.length ? rs[rs.length-1].type==='in' : false; };
  const duration = mins => `${Math.floor(mins/60)}h ${String(mins%60).padStart(2,'0')}min`;
  const escape = value => String(value).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  const showToast = (message, kind='success') => { const t=qs('#toast'); t.textContent=message; t.style.borderLeft=`3px solid ${kind==='error'?'#d7655a':'#72c69e'}`; t.classList.add('show'); setTimeout(()=>t.classList.remove('show'),3200); };
  const navigate = view => { qsa('.nav-item').forEach(b=>b.classList.toggle('active',b.dataset.view===view)); qsa('.view').forEach(v=>v.classList.toggle('active',v.id===`view-${view}`)); render(); window.scrollTo({top:0,behavior:'smooth'}); };
  const deviation = id => { const mins=minutesWorked(id); const inNow=isClockedIn(id); if(inNow && mins > STANDARD_MINUTES + 120) return 'danger'; if(!inNow && mins > STANDARD_MINUTES + TOLERANCE_MINUTES) return 'overtime'; if(!inNow && mins < STANDARD_MINUTES - TOLERANCE_MINUTES && recordsFor(id,true).length >= 2) return 'short'; return null; };
  const alerts = () => state.workers.map(w=>({w,kind:deviation(w.id),mins:minutesWorked(w.id)})).filter(x=>x.kind);

  function renderDashboard(){
    const present=state.workers.filter(w=>isClockedIn(w.id)), deviations=alerts(), total=state.workers.reduce((a,w)=>a+minutesWorked(w.id),0);
    qs('#stats-grid').innerHTML=`<div class="stat-card"><span class="stat-icon">♙</span><div class="stat-label">Presentes agora</div><div class="stat-value">${present.length}<small style="font:400 14px 'DM Sans';color:#9aa7b9"> / ${state.workers.length}</small></div><div class="stat-note positive">${present.length ? 'Equipe em atividade' : 'Ninguém em atividade'}</div></div><div class="stat-card"><span class="stat-icon">◷</span><div class="stat-label">Horas registradas hoje</div><div class="stat-value">${duration(total).replace(' ', ' ')}</div><div class="stat-note">Somatório da equipe</div></div><div class="stat-card"><span class="stat-icon">↗</span><div class="stat-label">Jornada média</div><div class="stat-value">${duration(state.workers.length ? Math.round(total/state.workers.length) : 0)}</div><div class="stat-note">Meta diária: 8h</div></div><div class="stat-card"><span class="stat-icon">!</span><div class="stat-label">Alertas pendentes</div><div class="stat-value">${deviations.length}</div><div class="stat-note ${deviations.length?'warn':'positive'}">${deviations.length?'Precisam de atenção':'Tudo dentro do esperado'}</div></div>`;
    qs('#presence-list').innerHTML=state.workers.map((w,i)=>`<div class="presence-row"><div class="person-avatar" style="background:${colors[i%colors.length].bg};color:${colors[i%colors.length].fg}">${initials(w.name)}</div><div class="person-info"><b>${escape(w.name)}</b><small>${escape(w.role)}</small></div><div class="presence-time"><b>${isClockedIn(w.id)?duration(minutesWorked(w.id)):'Fora do expediente'}</b><small>${isClockedIn(w.id)?'em atividade':'último status'}</small></div><span class="presence-status ${isClockedIn(w.id)?'in':'out'}"></span></div>`).join('');
    qs('#alerts-list').innerHTML=deviations.length?deviations.map(({w,kind,mins})=>`<div class="alert-row ${kind==='danger'?'danger':''}"><span class="alert-symbol">${kind==='short'?'↓':'↑'}</span><div><b>${escape(w.name)} <span class="muted">· ${kind==='short'?'jornada abaixo da meta':'jornada acima da meta'}</span></b><small>${duration(mins)} registrados · meta 8h</small></div></div>`).join(''):`<div class="empty-state">Nenhum desvio identificado hoje. ✦</div>`;
    qs('#alert-count').textContent=deviations.length;
    const recent=[...state.records].sort((a,b)=>new Date(b.createdAt)-new Date(a.createdAt)).slice(0,5);
    qs('#activity-table').innerHTML=tableHtml(recent,'activity');
  }
  function tableHtml(rs, mode){ if(!rs.length)return '<div class="empty-state">Nenhum registro encontrado.</div>'; return `<div class="table-wrap"><table class="data-table"><thead><tr><th>Trabalhador</th><th>Tipo</th><th>Data e hora</th><th>Origem</th>${mode==='audit'?'<th></th>':''}</tr></thead><tbody>${rs.map(r=>{const w=worker(r.workerId), e=effective(r);return `<tr><td><b>${escape(w?.name||'—')}</b><br><span class="muted">${w?.code||''}</span></td><td><span class="type-badge ${e.corrected?'type-correction':e.type==='in'?'type-in':'type-out'}">${e.corrected?'CORRIGIDO':e.type==='in'?'ENTRADA':'SAÍDA'}</span></td><td>${fmtDate(e.timestamp)} <b>${fmtTime(e.timestamp)}</b>${e.corrected?'<br><span class="muted">original: '+fmtTime(r.timestamp)+'</span>':''}</td><td>${e.corrected?'Admin · justificativa':'Terminal numérico'}</td>${mode==='audit'?`<td>${e.corrected?'<span class="muted">Correção registrada</span>':`<button class="correction-link" data-action="open-correction" data-id="${r.id}">Corrigir com justificativa</button>`}</td>`:''}</tr>`}).join('')}</tbody></table></div>`; }
  function renderWorkers(){const query=(qs('#worker-search')?.value||'').toLowerCase(); const ws=state.workers.filter(w=>`${w.name} ${w.code} ${w.role}`.toLowerCase().includes(query)); qs('#worker-total').textContent=`${state.workers.length} cadastrados`; qs('#workers-table').innerHTML=`<div class="table-wrap"><table class="data-table"><thead><tr><th>Trabalhador</th><th>Código único</th><th>Jornada hoje</th><th>Status</th><th>Cadastro</th></tr></thead><tbody>${ws.map((w,i)=>`<tr><td><div style="display:flex;align-items:center;gap:8px"><div class="person-avatar" style="background:${colors[i%colors.length].bg};color:${colors[i%colors.length].fg};margin:0">${initials(w.name)}</div><div><b>${escape(w.name)}</b><br><span class="muted">${escape(w.role)}</span></div></div></td><td><span class="highlight">${w.code}</span></td><td>${duration(minutesWorked(w.id))}</td><td><span class="status-pill ${isClockedIn(w.id)?'green':''}" style="display:inline-flex">${isClockedIn(w.id)?'<span></span>Em atividade':'Fora do expediente'}</span></td><td>${fmtDate(w.createdAt)}</td></tr>`).join('')}</tbody></table></div>`;}
  function renderAudit(){const corrections=state.corrections.length, original=state.records.length; qs('#audit-summary').innerHTML=`<div class="stat-card"><span class="stat-icon">⌁</span><div class="stat-label">Eventos registrados</div><div class="stat-value">${original+corrections}</div><div class="stat-note">Originais + correções</div></div><div class="stat-card"><span class="stat-icon">✓</span><div class="stat-label">Correções justificadas</div><div class="stat-value">${corrections}</div><div class="stat-note">Nunca removidas</div></div><div class="stat-card"><span class="stat-icon">◉</span><div class="stat-label">Taxa de integridade</div><div class="stat-value">100%</div><div class="stat-note positive">Trilha de auditoria ativa</div></div>`; const filter=qs('#audit-filter')?.value||'all'; let rs=[...state.records].sort((a,b)=>new Date(b.createdAt)-new Date(a.createdAt)); if(filter==='correction')rs=rs.filter(r=>state.corrections.some(c=>c.recordId===r.id)); if(filter==='punch')rs=rs.filter(r=>!state.corrections.some(c=>c.recordId===r.id)); qs('#audit-table').innerHTML=tableHtml(rs,'audit');}
  function render(){const active=qs('.view.active')?.id.replace('view-','')||'dashboard'; if(active==='dashboard')renderDashboard(); if(active==='trabalhadores')renderWorkers(); if(active==='auditoria')renderAudit(); updateClock();}
  function updateClock(){const now=new Date(); qs('#clock').textContent=now.toLocaleTimeString('pt-BR');}
  function openModal(content){qs('#modal-content').innerHTML=content;qs('#modal-backdrop').classList.add('show');}
  function closeModal(){qs('#modal-backdrop').classList.remove('show');}
  function openWorkerModal(){openModal(`<div class="modal-header"><div><h2>Novo trabalhador</h2><p>Crie um cadastro com um código numérico exclusivo.</p></div><button class="close-modal" data-action="close-modal">×</button></div><form id="worker-form"><div class="form-field"><label>Nome completo</label><input name="name" required placeholder="Ex.: Fernanda Souza" /></div><div class="form-field"><label>Área ou função</label><input name="role" required placeholder="Ex.: Financeiro" /></div><div class="form-field"><label>Código único (6 dígitos)</label><input name="code" required inputmode="numeric" pattern="[0-9]{6}" maxlength="6" placeholder="Ex.: 123456" /></div><div class="form-actions"><button type="button" class="button button-secondary" data-action="close-modal">Cancelar</button><button class="button button-primary">Cadastrar trabalhador</button></div></form>`); qs('#worker-form').addEventListener('submit', e=>{e.preventDefault(); const data=Object.fromEntries(new FormData(e.target)); if(state.workers.some(w=>w.code===data.code)){showToast('Este código já está em uso.','error');return;} state.workers.push({id:`w${Date.now()}`,...data,active:true,createdAt:new Date().toISOString()});save();closeModal();render();showToast('Trabalhador cadastrado com sucesso.');});}
  function openCorrection(id){const r=state.records.find(x=>x.id===id),w=worker(r.workerId),e=effective(r); openModal(`<div class="modal-header"><div><h2>Corrigir registro</h2><p>O registro original permanece preservado na trilha de auditoria.</p></div><button class="close-modal" data-action="close-modal">×</button></div><div class="tip-box"><span>!</span><div><b>${escape(w.name)} · ${e.type==='in'?'Entrada':'Saída'} original</b><p>${fmtDate(r.timestamp)} às ${fmtTime(r.timestamp)}</p></div></div><form id="correction-form"><div class="form-field"><label>Tipo correto</label><select name="type" style="width:100%"><option value="in" ${e.type==='in'?'selected':''}>Entrada</option><option value="out" ${e.type==='out'?'selected':''}>Saída</option></select></div><div class="form-field"><label>Data e hora corretas</label><input name="timestamp" type="datetime-local" required value="${r.timestamp.slice(0,16)}" /></div><div class="form-field"><label>Justificativa obrigatória</label><textarea name="reason" required placeholder="Explique o motivo da correção..."></textarea></div><div class="form-actions"><button type="button" class="button button-secondary" data-action="close-modal">Cancelar</button><button class="button button-primary">Salvar correção</button></div></form>`); qs('#correction-form').addEventListener('submit',ev=>{ev.preventDefault();const d=Object.fromEntries(new FormData(ev.target));state.corrections.push({id:`c${Date.now()}`,recordId:id,type:d.type,timestamp:new Date(d.timestamp).toISOString(),reason:d.reason,createdAt:new Date().toISOString(),createdBy:'Marina Costa'});save();closeModal();render();showToast('Correção registrada e vinculada ao original.');});}
  const CFG = (typeof window !== 'undefined' && window.PONTO_CONFIG) || {};
  const CLOUD = !!(CFG.url && CFG.anonKey);
  let sb = null;
  let sessao = null;
  async function cloudClient() {
    if (!CLOUD) return null;
    if (sb) return sb;
    const mod = await import('https://esm.sh/@supabase/supabase-js@2');
    sb = mod.createClient(CFG.url, CFG.anonKey);
    return sb;
  }
  const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; const v = c === 'x' ? r : (r & 0x3 | 0x8); return v.toString(16); }));
  async function rpcCall(fn, args, tentarDeNovo = true) {
    const client = await cloudClient();
    if (!client) throw new Error('sem_config');
    try {
      const { data, error } = await client.rpc(fn, args);
      if (error) throw error;
      return data;
    } catch (e) {
      const msg = String((e && e.message) || e);
      if (tentarDeNovo && /fetch|network|failed to fetch|load failed|timeout/i.test(msg)) {
        await new Promise(r => setTimeout(r, 800));
        return rpcCall(fn, args, false);
      }
      throw e;
    }
  }
  const erroAmigavel = (e) => {
    const m = String((e && e.message) || e);
    if (m.includes('credenciais_invalidas')) return 'Matrícula ou senha inválidas.';
    if (m.includes('funcionario_inativo')) return 'Funcionário inativo. Procure o RH.';
    if (m.includes('entrada_ja_aberta')) return 'Já existe uma entrada aberta hoje.';
    if (m.includes('sem_entrada_aberta')) return 'Não há entrada aberta para registrar a saída.';
    if (m.includes('nao_autenticado')) return 'Sessão expirada. Informe matrícula e senha novamente.';
    if (m.includes('tipo_invalido')) return 'Tipo de registro inválido.';
    if (m.includes('sem_config')) return 'Modo servidor não configurado.';
    if (/fetch|network|failed to fetch|load failed|timeout/i.test(m)) return 'Servidor indisponível. Tente novamente.';
    return 'Não foi possível concluir: ' + m;
  };
  async function submitPunchCloud(form) {
    const data = Object.fromEntries(new FormData(form));
    const matricula = (data.code || '').trim();
    const senha = (data.senha || '').trim();
    if (!matricula) { showToast('Informe a matrícula.', 'error'); qs('#punch-code').focus(); return; }
    if (!senha) { showToast('Informe a senha.', 'error'); qs('#punch-senha')?.focus(); return; }
    const tipo = data.type === 'in' ? 'entrada' : 'saida';
    const botao = qs('#punch-submit');
    if (botao) botao.disabled = true;
    try {
      if (!sessao || sessao.matricula !== matricula) {
        const r = await rpcCall('login', { p_matricula: matricula, p_senha: senha });
        sessao = { matricula, token: r.token, nome: r.funcionario.nome };
      }
      const reg = await rpcCall('registrar_ponto', { p_token: sessao.token, p_tipo: tipo, p_origem: 'terminal-web', p_request_id: uuid() });
      const rotulo = tipo === 'entrada' ? 'Entrada' : 'Saída';
      qs('#punch-success-message').textContent = `${sessao.nome} · ${rotulo} às ${fmtTime(reg.timestamp_utc)}. Próximo trabalhador pode registrar.`;
      qs('#punch-success').classList.add('show');
      form.reset();
      qsa('.punch-type').forEach(x => x.classList.remove('selected'));
      qs('.punch-type[data-type="in"]').classList.add('selected');
      showToast('Registro salvo no servidor com sucesso.');
    } catch (e) {
      showToast(erroAmigavel(e), 'error');
    } finally {
      if (botao) botao.disabled = false;
      qs('#punch-code').focus();
    }
  }
  function submitPunch(event){if(event)event.preventDefault();const form=qs('#punch-form');if(!form)return;if(CLOUD)return submitPunchCloud(form);const data=Object.fromEntries(new FormData(form));const code=(data.code||'').trim();const w=state.workers.find(x=>x.code===code);if(!w){showToast('Código não encontrado. Confira os 6 dígitos e tente novamente.','error');qs('#punch-code').focus();return;}const type=data.type;if(type==='in'&&isClockedIn(w.id)){showToast(`${w.name} já possui uma entrada aberta. Registre a saída ou corrija pela auditoria.`,'error');return;}if(type==='out'&&!isClockedIn(w.id)){showToast(`${w.name} não possui uma entrada aberta para registrar saída.`,'error');return;}const now=new Date().toISOString();state.records.push({id:`r${Date.now()}`,workerId:w.id,type,timestamp:now,createdAt:now,createdBy:'Terminal compartilhado'});save();form.reset();qs('.punch-type[data-type="in"]').classList.add('selected');qsa('.punch-type[data-type="out"]').forEach(x=>x.classList.remove('selected'));qs('#punch-success-message').textContent=`${w.name} · ${type==='in'?'Entrada':'Saída'} às ${fmtTime(now)}. Próximo trabalhador pode registrar.`;qs('#punch-success').classList.add('show');qs('#punch-code').focus();showToast('Registro salvo com sucesso.');render();}
  function initPunchForm(){qs('#punch-form').addEventListener('submit',submitPunch);qs('#punch-code').addEventListener('input',e=>{e.target.value=e.target.value.replace(/\D/g,'').slice(0,6);});qsa('.punch-type').forEach(option=>option.addEventListener('click',()=>{qsa('.punch-type').forEach(x=>x.classList.remove('selected'));option.classList.add('selected');option.querySelector('input').checked=true;}));qsa('.mock-worker').forEach(button=>button.addEventListener('click',()=>{qs('#punch-code').value=button.dataset.mockCode;qs('#punch-code').focus();showToast('Código de teste preenchido. Escolha entrada ou saída.');}));}
  document.addEventListener('click',e=>{const nav=e.target.closest('[data-view]');if(nav)navigate(nav.dataset.view);const action=e.target.closest('[data-action]');if(!action)return;const a=action.dataset.action;if(a==='go-ponto')navigate('ponto');if(a==='go-trabalhadores')navigate('trabalhadores');if(a==='go-auditoria')navigate('auditoria');if(a==='open-worker-modal')openWorkerModal();if(a==='open-correction')openCorrection(action.dataset.id);if(a==='close-modal')closeModal();});
  initPunchForm(); qs('#worker-search').addEventListener('input',renderWorkers); qs('#audit-filter').addEventListener('change',renderAudit); qs('#modal-backdrop').addEventListener('click',e=>{if(e.target.id==='modal-backdrop')closeModal();}); render(); setInterval(updateClock,1000); setInterval(render,60000);
})();
