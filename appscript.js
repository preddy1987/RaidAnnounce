function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Raid')
    .addItem('Build Export (Lua)', 'buildLua')
    .addItem('Help (named ranges)', 'showHelp')
    .addToUi();
}

/* ------------ tiny helpers ------------ */
function _trim(s){ return (s==null?'':String(s)).replace(/\u00A0/g,' ').replace(/\s+/g,' ').trim(); }
function _isBlank(s){ return !_trim(s); }
function _lc(s){ return _trim(s).toLowerCase(); }
function _isStopword(s){
  var t=_lc(s);
  var bad={
    'raid':1,'raids':1,'tanks':1,'tank':1,'healers':1,'heals':1,'dps':1,'melee':1,'ranged':1,
    'everyone':1,'all':1,'none':1,'tbd':1,'na':1,'n/a':1,'group':1,'groups':1
  }; return !!bad[t];
}
function _looksName(s){
  var t=_trim(s); if (!t) return false;
  if (_isStopword(t)) return false;
  // one token of letters/diacritics/'- ; tolerate UTF-8 names
  return /^[A-Za-zÀ-ÖØ-öø-ÿ'\-]+$/.test(t);
}
function _get(name){
  var ss=SpreadsheetApp.getActive();
  var nr=ss.getRangeByName(name);
  return nr ? nr.getDisplayValues() : null;
}
function _luaStr(s){ return '"' + String(s||'').replace(/\\/g,'\\\\').replace(/"/g,'\\"') + '"'; }
function _luaArr(arr){ return '{ ' + (arr||[]).map(_luaStr).join(', ') + ' }'; }
function _luaMapNumStr(obj){
  var keys=Object.keys(obj||{}).sort(function(a,b){return (+a)-(+b);});
  return '{ ' + keys.map(function(k){ return '['+k+'] = ' + _luaStr(obj[k]); }).join(', ') + ' }';
}
function _luaMapStrStr(obj){
  var keys=Object.keys(obj||{});
  return '{ ' + keys.map(function(k){ return k + ' = ' + _luaStr(obj[k]); }).join(', ') + ' }';
}
function _luaArrArr(rows){
  // rows: Array<Array<string>>
  var parts = rows.map(function(r){
    return '{ ' + r.map(_luaStr).join(', ') + ' }';
  });
  return '{ ' + parts.join(', ') + ' }';
}

/* ------------ parsers (simple, deterministic) ------------ */
function readList(name){
  // Returns array of valid names from a named range (any shape → flattened)
  var v=_get(name); if (!v) return [];
  var out=[];
  for (var r=0;r<v.length;r++){
    for (var c=0;c<v[0].length;c++){
      var s=_trim(v[r][c]);
      if (s && _looksName(s)) out.push(s);
    }
  }
  return out;
}

function readSingle(name){
  // First valid name/string from a range, or "" if none
  var a=readList(name);
  return a.length? a[0] : "";
}

function readKicks(name){
  // Expects 1 column, rows 1..5 (or 2 cols: [index, name])
  var v=_get(name); if (!v) return {};
  var m={};
  for (var r=0;r<v.length;r++){
    var left=_trim(v[r][0]||"");
    var right=(v[0].length>1)? _trim(v[r][1]||"") : "";
    var idx=null, nm="";
    // detect "1", "G1", "1st Kick", "Kick 1" etc.
    var lcl=_lc(left);
    var mNum = left.match(/^\s*(?:g|grp|group)?\s*([1-5])\b/i) || lcl.match(/(?:^|\s)([1-5])(?:st|nd|rd|th)?\s*kick\b/) || lcl.match(/kick\s*([1-5])\b/);
    if (mNum) idx=+mNum[1];
    if (!idx && v[0].length===1) idx=r+1; // plain list order
    if (v[0].length===1) nm=left; else nm=right;
    if (idx && _looksName(nm)) m[idx]=nm;
  }
  return m;
}

function readHealAssign(){
  var v = _get('HealAssign'); if (!v) return [];
  var out = [];
  var R = Math.min(v.length, 8);
  for (var r=0; r<R; r++){
    var tank  = _trim(v[r][0] || "");
    var h1    = _trim(v[r][1] || "");
    var h2    = _trim(v[r][2] || "");
    // keep blanks as "" so Lua rows are always length-3
    // but drop rows with no tank name at all
    if (_looksName(tank)) out.push([tank, h1, h2]);
  }
  return out;
}

function readGroupMap(name){
  // Accepts 2-col [group, name] or 1-col 8 rows (group order)
  var v=_get(name); if (!v) return {};
  var m={}, R=v.length, C=v[0].length;
  function toGroup(s){
    var t=_trim(s);
    var g=null;
    var mm=t.match(/^(?:g|grp|group)?\s*([1-8])\b/i); if (mm) g=+mm[1];
    if (g==null && /^[1-8]$/.test(t)) g=+t;
    return g;
  }
  if (C>=2){
    for (var r=0;r<R;r++){
      var g=toGroup(v[r][0]); var nm=_trim(v[r][1]||"");
      if (g && _looksName(nm)) m[g]=nm;
    }
  } else {
    for (var r=0;r<Math.min(8,R); r++){
      var nm=_trim(v[r][0]||"");
      if (_looksName(nm)) m[r+1]=nm;
    }
  }
  return m;
}

function buildLua(){
  // ---- collect data from named ranges ----
  var tanks     = readList('Tanks');
  var kicksMap  = readKicks('Kicks');
  var tranq     = readList('Tranq');
  var fearWard  = readList('FearWard');
  var healAssign = readHealAssign();

  var aiMap     = readGroupMap('AI');
  var fortMap   = readGroupMap('Fort');
  var shadowMap = readGroupMap('Shadow');
  var healsMap  = readGroupMap('Heals');

  var buffs = {
    pally: {
      might_wisdom: readSingle('Pally_MightWisdom'),
      kings:        readSingle('Pally_Kings'),
      light:        readSingle('Pally_Light'),
      salv_sanct:   readSingle('Pally_SalvSanct')
    }
  };
  var debuffs = {
    recklessness:  readSingle('Debuff_Recklessness'),
    elements:      readSingle('Debuff_Elements'),
    shadows:       readSingle('Debuff_Shadows'),
    demo_shout:    readSingle('Debuff_DemoShout'),
    thunderclap:   readSingle('Debuff_Thunderclap')
  };

  // kicks array [1..5]
  var kicks = {};
  for (var i=1;i<=5;i++) kicks[i]=kicksMap[i]||"";

  // ---- compose Lua ----
  var body =
    '  groups = { },\n' +
    '  buffs = { pally = ' + _luaMapStrStr(buffs.pally) + ' },\n' +
    '  debuffs = ' + _luaMapStrStr(debuffs) + ',\n' +
    '  priests = { fort = ' + _luaMapNumStr(fortMap) + ', shadow = ' + _luaMapNumStr(shadowMap) + ' },\n' +
    '  mages   = { ai = ' + _luaMapNumStr(aiMap) + ' },\n' +
    '  kicks = { ' + [1,2,3,4,5].map(function(i){ return '['+i+'] = ' + _luaStr(kicks[i]); }).join(', ') + ' },\n' +
    '  tranq = ' + _luaArr(tranq) + ',\n' +
    '  fear_ward = ' + _luaArr(fearWard) + ',\n' +
    '  heals = ' + _luaMapNumStr(healsMap) + ',\n' +
    '  heal_assign = ' + _luaArrArr(healAssign) + ',\n' +   // <--- NEW
    '  tanks = ' + _luaArr(tanks) + ',\n';

  var luaAssign = 'MyRaidData = {\n' + body + '}\n';
  var luaReturn = 'return {\n' + body + '}\n';

  var html = HtmlService.createHtmlOutput(
    '<h3>SavedVariables Export</h3>' +
    '<p>Output matches named ranges exactly—no guessing.</p>' +
    '<p><label><input type="radio" name="fmt" value="assign" checked> <code>MyRaidData = { ... }</code></label> ' +
    '<label><input type="radio" name="fmt" value="return"> <code>return { ... }</code></label></p>' +
    '<textarea id="out" style="width:100%;height:420px;white-space:pre;">'+luaAssign+'</textarea>' +
    '<script>(function(){var A='+JSON.stringify(luaAssign)+',B='+JSON.stringify(luaReturn)+';var r=document.getElementsByName("fmt");for(var i=0;i<r.length;i++){r[i].addEventListener("change",function(){document.getElementById("out").value=(this.value==="assign")?A:B;});}})();</script>'
  ).setWidth(860).setHeight(680);
  SpreadsheetApp.getUi().showModalDialog(html, 'RaidAnnounce Export');
}

function showHelp(){
  var msg =
`Name these ranges (Data → Named ranges). Shapes:

Tanks:        1 column list (top to bottom = MT, OT1, OT2, ...)
Kicks:        either 1 column (rows 1..5) OR 2 cols [index, name]
Tranq:        1 column list
FearWard:     1 column list
HealAssign:    3 columns, up to 8 rows -> [Tank | HealerA | HealerB]

AI:           either 2 cols [group, name] (group can be 1..8 or G1..G8) OR 1 col (8 rows = groups 1..8)
Fort:         same as AI
Shadow:       same as AI
Heals:        same as AI (you can comma-separate multiple healers in the name cell if you want)

Pally_MightWisdom: single cell (or list; first cell used)
Pally_Kings:       single cell
Pally_Light:       single cell
Pally_SalvSanct:   single cell

Debuff_Recklessness, Debuff_Elements, Debuff_Shadows, Debuff_DemoShout, Debuff_Thunderclap: single cell (or list; first cell used)

Tip: cells like "Raid" or "Tanks" are ignored (treated as labels, not names).`;
  SpreadsheetApp.getUi().alert(msg);
}
