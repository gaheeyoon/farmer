/* Public field records. Usage dates and full quantities confirmed by the grower. */
window.FARMER_TMI = {
 season: 2026,
 weather: { latitude: 36.83, longitude: 126.27, label: '태안군 원북면 원이로 인근', start: '2026-06-07', end: '2026-10-15' },
 supplies: [
  {id:'s1',date:'2026-04-24',name:'미즈카네(썬그린)',packKg:20,packs:2,npk:null},
  {id:'s2',date:'2026-04-24',name:'조비 미래로뿌리왕',packKg:20,packs:5,npk:[11,8,9]},
  {id:'s3',date:'2026-05-06',name:'고구마한방',packKg:20,packs:6,npk:[9,9,20]},
  {id:'s4',date:'2026-05-06',name:'포스',packKg:2,packs:6,npk:null},
  {id:'s5',date:'2026-05-11',name:'입상붕사',packKg:1,packs:3,npk:null},
  {id:'s6',date:'2026-05-11',name:'원예맞춤1호 · 황산가리',packKg:20,packs:2,npk:[0,0,45]},
  {id:'s7',date:'2026-05-06',name:'LD흑유 비닐',quantity:3,unit:'개',spec:'0.015 × 90 × 1000 (22cm, 무)',kind:'cover',npk:null}
 ],
 // Characters are symbolic, not portraits. A repeated person keeps the same avatar.
 people: [
  {step:'01',label:'방향을 알려준 사람들',scene:'guidance',title:'무엇을 심을지부터, 함께 고민했습니다.',intro:'갑자기 생긴 밭 앞에서 무엇부터 해야 할지 몰랐습니다. 귀농귀촌을 안내해 준 분들, 군청의 여러 부서와 이웃들에게 묻고 또 물었습니다.',groups:[
   {task:'귀농귀촌 안내',people:[{id:'guidance-team',name:'농업기술센터',detail:'귀농귀촌팀',kind:'org',avatar:0,prop:'book'}]},
   {task:'농지를 구매하기 위한 상담',people:[{id:'county-farm',name:'군청 농정과',kind:'org',avatar:1,prop:'clipboard'},{id:'county-help',name:'군청 신속민원처리과',kind:'org',avatar:2,prop:'clipboard'}]},
   {task:'가까이에서 들려준 조언',people:[{id:'neighbors',name:'주변 이웃들',kind:'group',avatars:[3,4],prop:'sprout'}]},
   {task:'농지 대출',note:'귀농농업창업및주택구입지원사업',people:[{id:'yun-heejae',name:'윤희재 계장님',detail:'원북 농협',avatar:31,prop:'clipboard'}]}
  ]},
  {step:'02',label:'밭을 준비한 손길',scene:'prepare',title:'심기 전에, 땅부터 준비했습니다.',intro:'농업기술센터에서 토양검사를 받고, 트랙터로 밭을 갈고 이랑과 고랑을 만들었습니다. 고구마를 심을 자리가 그렇게 준비됐습니다.',groups:[
   {task:'포크레인으로 잡목 제거 · 땅 정리',people:[{id:'eosong',name:'어송환경',kind:'org',avatar:30,prop:'excavator'}]},
   {task:'토양검사',people:[{id:'soil-team',name:'농업기술센터',detail:'토양검사',kind:'org',avatar:5,prop:'soil'}]},
   {task:'트랙터 작업',people:[{id:'jeong',name:'정창득 선생님',detail:'로터리 · 이랑과 고랑 만들기',avatar:6,prop:'tractor'}]},
   {task:'농자재 판매',people:[{id:'hyundae',name:'현대농자재마트',kind:'org',avatar:27,prop:'supplies'}]},
   {task:'비닐하우스',people:[{id:'seohaean',name:'서해안하우스',kind:'org',avatar:29,prop:'greenhouse'}]}
  ]},
  {step:'03',label:'함께 걱정하고 보탠 손',scene:'growing',title:'배우고, 심고, 함께 키웠습니다.',intro:'600평에 고구마 8,000주를 심었습니다. 재배 방법을 알려주신 분, 순을 챙겨주신 분, 직접 밭에서 손을 보태주신 분들. 음악하는 홍세환과 개발하는 윤가희도 그 사이에서 농사를 배웠습니다.',groups:[
   {task:'고구마 재배 방법',people:[{id:'myeong',name:'명재행 선생님',avatar:7,prop:'book'},{id:'kim',name:'김정숙 선생님',avatar:8,prop:'sprout'}]},
   {task:'고구마 심기 조언',people:[{id:'igok',name:'이곡서점 작은 사장님',avatar:28,prop:'book'}]},
   {task:'고구마 순',people:[{id:'lee',name:'이용복 선생님',avatar:9,prop:'sprout'}]},
   {task:'고구마 심기',people:[{id:'mom',name:'엄마',avatar:10,prop:'shovel'},{id:'hyojin',name:'효진 선생님',detail:'낙원요가',avatar:11,prop:'sprout'},{id:'gori',name:'고리 님',detail:'토토스튜디오',avatar:12,prop:'shovel'},{id:'park-hyangseon',name:'박향선',detail:'도래푸드',avatar:32,prop:'sprout'},{id:'kim-minseok',name:'김민석',detail:'도래푸드',avatar:33,prop:'shovel'}]},
   {task:'세 명의 아이들도 함께',note:'고구마 심기',postscript:'P.S. 고사리손조차 절실했던 시기',people:[{id:'yunseo',name:'홍윤서',avatar:13,child:true,prop:'sprout'},{id:'seoyun',name:'홍서윤',avatar:14,child:true,prop:'heart'},{id:'seowoo',name:'홍서우',avatar:15,child:true,prop:'sprout'}]},
   {task:'지하수와 전기를 빌려주신',people:[{id:'water',name:'OOO 선생님',avatar:16,prop:'water'}]},
   {task:'매일을 배운 두 사람',note:'시작은 어쩌다, 농사는 진심.',people:[{id:'sehwan',name:'홍세환',detail:'음악하는',avatar:17,prop:'music'},{id:'gahee',name:'윤가희',detail:'개발하는',avatar:18,prop:'laptop'}]}
  ]},
  {step:'04',label:'수확',scene:'harvest',date:'2026. 10. 15. 첫 수확',title:'땅속의 고구마를, 함께 꺼냈습니다.',intro:'드디어 첫 고구마를 수확했습니다. 수확기 임대부터 트랙터 작업, 밭에서 함께한 손길과 큐어링까지. 수확의 기쁨 뒤에도 고마운 사람들이 있었습니다.',groups:[
   {task:'고구마 수확기 임대',people:[{id:'rental',name:'태안농기계임대사업소',kind:'org',avatar:19,prop:'tractor'}]},
   {task:'트랙터 수확',people:[{id:'jeong',name:'정창득 선생님',avatar:6,prop:'tractor'}]},
   {task:'수확 현장에 함께한 손',people:[{id:'workers',name:'반도인력',detail:'4명',kind:'group',avatars:[20,21,22,23],prop:'crate'},{id:'eunbyeol',name:'은별 님',avatar:24,prop:'crate'},{id:'jina',name:'지나 언니',avatar:25,prop:'shovel'}]},
   {task:'큐어링',people:[{id:'byun',name:'변학수 선생님',detail:'태안농산',avatar:26,prop:'crate'}]},
   {task:'콘티 박스 판매',people:[{id:'myeong',name:'명재행 선생님',avatar:7,prop:'crate'},{id:'kim',name:'김정숙 선생님',avatar:8,prop:'crate'}]}
  ]}
 ]
};
