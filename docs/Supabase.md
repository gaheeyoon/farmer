# Supabase 연결과 점검

## 배포 구조

정적 웹사이트 → Supabase 공개 API → 권한을 검사하는 PostgreSQL 함수입니다. 프로젝트 URL과 공개 publishable key만 `farmer-config.js`에 둡니다. secret/service_role key는 브라우저나 공개 저장소에 두지 않습니다.

처음 설치할 때 `supabase/migrations`를 순서대로 적용합니다. 초기 재고와 관리자 이메일 허용 목록은 운영 데이터로 별도 입력하며, 기존 재고를 재배포할 때 덮어쓰지 않습니다. 관리자 이메일은 `farmer_private.admin_emails`에 소문자로 등록합니다. Auth의 동일 이메일 계정이 이메일 확인을 완료해야 권한이 생깁니다.

새 호스트에서 이메일 확인 후 자동으로 관리자 화면을 열려면 Supabase Authentication → URL Configuration에서 실제 사이트의 `/admin.html`을 Site URL 또는 Redirect URL 허용 목록에 지정하세요. 현재 관리자 계정의 이메일 인증 및 로그인 기록은 확인했습니다. 대시보드 URL 설정은 이번 연결 도구에서 변경하지 않았습니다.

## 데이터

- `farmer_orders`: 주문 당시 상품·가격·할인·배송비, 주문자 및 받는 분 연락처·우편번호·주소, 묶음 번호·배송지 순서, 상태, 동의·확정·발송·완료 시각
- `farmer_inventory`: 판매 가능 재고. 내부 단위는 정수 g, 표시 단위는 kg
- `farmer_stock_events`: 재고 변동, 이유, 잔고, 실행 관리자
- `farmer_order_events`: 주문 상태 변경 이력, 실행 관리자
- `farmer_products`: 상품별 중량·가격·판매 여부
- `farmer_private.admin_emails`, `discount_codes`: 관리자 허용 목록과 할인코드
- `farmer_private.order_batches`: 여러 배송지의 요청 UUID, 입력 지문, 접수 결과. 직접 조회는 차단합니다.

상태 변경과 재고 변경은 한 트랜잭션으로 저장합니다. 주문·재고 잠금으로 동시 확정 시 초과 차감을 막습니다. 요청 UUID는 동일 요청 재시도를 구분하며, 편집 버전은 오래된 화면에서 덮어쓰는 일을 막습니다.

`farmer_admin_bulk_status(p_orders, p_status)`는 1~50개 주문을 한 트랜잭션에서 처리합니다. 관리자 검사를 통과한 뒤 주문 ID 순서로 잠그고, 기존 단건 상태 전환 함수를 호출합니다. `p_orders`의 각 항목은 `order_id`, `expected_version`, `request_id`, `carrier`, `tracking_number`입니다. 중복 주문·요청은 거부합니다. 입금 확인·배송 중·배송 완료만 지원하며 재고 부족, 버전 충돌, 잘못된 전환, 배송 방법 누락 시 전체가 롤백됩니다. 재시도에는 같은 요청 UUID를 사용합니다. 기존 상태 코드와 주문 데이터는 변경하지 않습니다.

`farmer_quote_batch`는 최대 20개 배송지를 계산하고 각 배송지의 상품 금액에 10% 할인과 배송지별 배송비를 적용합니다. 원 미만은 배송지별로 버립니다. `farmer_submit_batch`는 모든 배송지를 한 트랜잭션으로 저장합니다. 한 배송지가 잘못되면 전체가 롤백됩니다. 같은 UUID의 재시도는 기존 결과를 반환하고, 다른 내용으로 UUID를 재사용하면 거부합니다. 같은 주문자라도 새 UUID로 별도 주문을 접수할 수 있습니다. 기존 단일 배송지 RPC는 이전 사이트 버전과의 호환을 위해 유지합니다. `20261018010138_percentage_discount.sql`는 새 주문의 할인 계산만 변경하며, 기존 주문의 저장 금액과 재시도 결과는 유지합니다.

입금 대기는 기존 `pending` 상태를 표시한 이름입니다. 접수 시 결제 완료로 기록하지 않습니다. 관리자가 은행 입금을 확인하고 주문을 확정하면 `confirmed`와 확정 시각을 기록하고 재고를 차감합니다.

주소 검색은 [카카오 공식 우편번호 SDK](https://postcode.map.kakao.com/guide)를 필요할 때만 불러옵니다. API 키가 필요 없는 검색 서비스이며, 우편번호와 주소를 반환받은 뒤 상세 주소는 고객이 입력합니다. 검색 실패 시 수동 입력 경로도 제공합니다.

`farmer_lookup_orders(p_customer_name, p_phone, p_offset)`는 주문자 이름과 정규화한 연락처가 모두 일치하는 주문만 최신순 20건씩 반환합니다. 기존 단일 주문과 여러 번 접수한 주문도 포함합니다. 이름·연락처는 인증 수단이 아니므로 받는 분 이름은 마스킹하고 주소·연락처·메모·내부 식별자는 반환하지 않습니다. 상품·금액·현재 상태와 주문일/완료일만 반환합니다. 실패 응답은 동일하며 `farmer_private.order_lookup_limits`에 연락처의 해시별로 15분/20회 제한을 기록합니다. 실패 시 예외 대신 JSON을 반환해 횟수가 롤백되지 않게 합니다. 테이블 직접 접근 권한은 열지 않습니다.

## 보안 검사

모든 테이블에 RLS를 켜고 anon/authenticated의 직접 접근 권한을 제거했습니다. 공개 함수는 상품 조회·금액 계산·접수와 제한된 고객 주문 조회를 제공합니다. 관리자 함수는 모든 호출마다 `auth.uid()`에 해당하는 사용자의 인증된 이메일을 비공개 허용 목록과 대조합니다. 함수의 검색 경로는 고정되어 있습니다.

Supabase Advisor의 다음 항목은 이 구조에서 의도된 구성에 대한 검토 항목입니다. 무조건 허용 정책을 추가하거나 관리자 검사를 제거하지 마세요.

- [RLS enabled, no policy](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy): 테이블 직접 접근을 전부 거부하고 명시된 함수만 사용합니다.
- [Anonymous SECURITY DEFINER](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable): 비로그인 고객에게 필요한 상품 조회, 단일·묶음 금액 계산·접수 및 마스킹된 주문 조회 함수만 공개했습니다.
- [Authenticated SECURITY DEFINER](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable): 관리자 함수의 실행 권한만으로는 부족하며 내부 관리자 확인을 통과해야 합니다.
- [Unindexed foreign keys](https://supabase.com/docs/guides/database/database-linter?lint=0001_unindexed_foreign_keys): 상품 및 주문 묶음 외래키 인덱스를 추가했습니다. 신규 데이터베이스의 unused index 안내는 운영 후 사용량을 보고 판단합니다.

2026-10-18 Advisor는 [유출 비밀번호 차단](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)이 꺼져 있다는 항목도 보고했습니다. 계정 인증 설정은 이번 주문서 수정에서 변경하지 않았으며, 관리자가 Supabase Auth 설정에서 별도로 검토할 수 있습니다.

## 검증 범위

2026-10-18 기준:

- PGlite PostgreSQL에서 실제 migration을 실행하고 비로그인/비관리자/미인증 관리자 접근 거부, 가격 변조 거부, 할인·수량 검사, 접수 중복 방지, 재고 부족·버전 충돌, 취소 복구, 발송·배송 완료 및 재고 조정을 검증했습니다. 2kg·5kg 및 복수 수량·배송지의 10% 할인 적용, 배송지별 배송비, 전체 롤백, 동일 요청 재시도, 같은 주문자의 추가 주문과 우편번호·받는 분 정보도 검사했습니다.
- 운영 API의 상품·할인 계산을 조회했습니다. 5kg 1개 + GOGUMA = 21,500원이며, 익명 주문 테이블 조회와 관리자 함수 호출은 차단됩니다. 두 배송지(2kg × 1, 5kg × 2)의 금액은 50,000 + 7,000 − 5,000 = 52,000원으로 확인했습니다.
- 브라우저에서 실제 운영 상품·금액 조회를 사용했습니다. 주문 제출과 관리자 변경은 응답을 모의해 검사했으며 운영 데이터에 검증용 주문을 남기지 않았습니다.
- 320·390·768·1440px 화면 표시, 주문/조회 탭 분리, 단일 버튼 주문 접수, 연결 실패 시 같은 UUID 재시도, 고객 텍스트의 스크립트 실행 방지, 로그아웃 시 화면 정보 제거를 확인했습니다. 실제 카카오 검색으로 우편번호·주소 선택, 반복 검색, 검색 연결 실패 후 수동 입력, 자동 전화번호 표시와 받는 분 추가·삭제도 확인했습니다.

- 이름·연락처 일치/불일치, 기존 주문, 반복 주문, 페이지 나누기, 마스킹, 현재 배송 상태, 조회 횟수 제한·만료와 입력 변경 시 이전 결과 숨김을 검사했습니다.
- 일괄 상태 변경의 관리자 권한, 네 단계 전환, 재고 부족·버전 충돌·배송 정보 오류 시 전체 롤백, 개별 송장 저장, 동일 요청 재시도 및 이후 단계에서도 과거 요청이 상태를 되돌리지 않는 동작을 검사했습니다. 브라우저 모의 데이터로 전체/개별 선택, 혼합 단계 방지, 단계 필터, 재시도 입력 고정, 처리 중 로그아웃과 390·1440px 표시를 확인했습니다. 운영 변경 전후 주문 상태와 재고가 동일함을 확인했습니다.

자동 입금 확인, 택배사 연동, 주문 알림은 검증 범위에 포함되지 않으며 구현되어 있지 않습니다. 재고 화면은 자동 갱신이 아니라 새로고침 버튼으로 최신 상태를 조회합니다.
