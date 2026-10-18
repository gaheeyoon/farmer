# Supabase 연결과 점검

## 배포 구조

정적 웹사이트 → Supabase 공개 API → 권한을 검사하는 PostgreSQL 함수입니다. 프로젝트 URL과 공개 publishable key만 `farmer-config.js`에 둡니다. secret/service_role key는 브라우저나 공개 저장소에 두지 않습니다.

처음 설치할 때 `supabase/migrations`를 순서대로 적용합니다. 초기 재고와 관리자 이메일 허용 목록은 운영 데이터로 별도 입력하며, 기존 재고를 재배포할 때 덮어쓰지 않습니다. 관리자 이메일은 `farmer_private.admin_emails`에 소문자로 등록합니다. Auth의 동일 이메일 계정이 이메일 확인을 완료해야 권한이 생깁니다.

새 호스트에서 이메일 확인 후 자동으로 관리자 화면을 열려면 Supabase Authentication → URL Configuration에서 실제 사이트의 `/admin.html`을 Site URL 또는 Redirect URL 허용 목록에 지정하세요. 현재 관리자 계정의 이메일 인증 및 로그인 기록은 확인했습니다. 대시보드 URL 설정은 이번 연결 도구에서 변경하지 않았습니다.

## 데이터

- `farmer_orders`: 주문 당시 상품·가격·할인·배송비, 연락처·주소, 상태, 동의·확정·발송·완료 시각
- `farmer_inventory`: 판매 가능 재고. 내부 단위는 정수 g, 표시 단위는 kg
- `farmer_stock_events`: 재고 변동, 이유, 잔고, 실행 관리자
- `farmer_order_events`: 주문 상태 변경 이력, 실행 관리자
- `farmer_products`: 상품별 중량·가격·판매 여부
- `farmer_private.admin_emails`, `discount_codes`: 관리자 허용 목록과 할인코드

상태 변경과 재고 변경은 한 트랜잭션으로 저장합니다. 주문·재고 잠금으로 동시 확정 시 초과 차감을 막습니다. 요청 UUID는 동일 요청 재시도를 구분하며, 편집 버전은 오래된 화면에서 덮어쓰는 일을 막습니다.

## 보안 검사

모든 테이블에 RLS를 켜고 anon/authenticated의 직접 접근 권한을 제거했습니다. 공개 함수는 상품 조회·금액 계산·접수만 제공합니다. 관리자 함수는 모든 호출마다 `auth.uid()`에 해당하는 사용자의 인증된 이메일을 비공개 허용 목록과 대조합니다. 함수의 검색 경로는 고정되어 있습니다.

Supabase Advisor의 다음 항목은 이 구조에서 의도된 구성에 대한 검토 항목입니다. 무조건 허용 정책을 추가하거나 관리자 검사를 제거하지 마세요.

- [RLS enabled, no policy](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy): 테이블 직접 접근을 전부 거부하고 명시된 함수만 사용합니다.
- [Anonymous SECURITY DEFINER](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable): 비로그인 고객에게 필요한 세 함수만 공개했습니다.
- [Authenticated SECURITY DEFINER](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable): 관리자 함수의 실행 권한만으로는 부족하며 내부 관리자 확인을 통과해야 합니다.
- [Unindexed foreign keys](https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys): 상품 외래키 인덱스를 추가했습니다. 신규 데이터베이스의 unused index 안내는 운영 후 사용량을 보고 판단합니다.

## 검증 범위

2026-10-18 기준:

- PGlite PostgreSQL에서 실제 migration을 실행하고 비로그인/비관리자/미인증 관리자 접근 거부, 가격 변조 거부, 할인·수량 검사, 접수 중복 방지, 재고 부족·버전 충돌, 취소 복구, 발송·배송 완료 및 재고 조정을 검증했습니다.
- 운영 API의 상품·할인 계산을 조회했습니다. 5kg 1개 + GOGUMA = 21,500원이며, 익명 주문 테이블 조회와 관리자 함수 호출은 차단됩니다.
- 브라우저에서 실제 운영 상품·금액 조회를 사용했습니다. 주문 제출과 관리자 변경은 응답을 모의해 검사했으며 운영 데이터에 검증용 주문을 남기지 않았습니다.
- 390px 모바일과 1440px 데스크톱 표시, 주문 입력 변경 후 재확인, 연결 실패 시 같은 UUID 재시도, 고객 텍스트의 스크립트 실행 방지, 로그아웃 시 화면 정보 제거를 확인했습니다.

실제 결제, 택배사 연동, 주문 알림은 검증 범위에 포함되지 않으며 구현되어 있지 않습니다. 재고 화면은 자동 갱신이 아니라 새로고침 버튼으로 최신 상태를 조회합니다.
