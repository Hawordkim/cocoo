#!/bin/bash
#
# Mindglow "Quick Setup WordPress on Ubuntu" AMI용으로 수정
# WordPress DB를 로컬에서 AWS RDS로 마이그레이션하는 스크립트
# 사용법: ./oneshot.sh <로컬DB_root비밀번호> <RDS_admin비밀번호> <RDS_엔드포인트>
#

# ===== 경로 설정 =====
WP_HOME=/var/www/html
WP_CONFIG=${WP_HOME}/wp-config.php
BACKUP_DIR=${HOME}/migration_backup_$(date +%Y%m%d_%H%M%S)
AWS_REGION=us-east-1
SSL_PEM=${BACKUP_DIR}/${AWS_REGION}-bundle.pem
SSL_OPTS="--ssl-ca=${SSL_PEM} --ssl-mode=VERIFY_IDENTITY"

# ===== 컬러 및 출력 함수 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step_header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

# ===== 인자 확인 =====
if [ "$#" -ne 3 ]; then
    echo "사용법: $0 <로컬DB_root비밀번호> <RDS_admin비밀번호> <RDS_엔드포인트>"
    echo "  예시: $0 localRootPw rdsAdminPw mydb.abc123.${AWS_REGION}.rds.amazonaws.com"
    exit 1
fi

LOCAL_ROOT_PW=$1
RDS_ADMIN_PW=$2
RDS_ADDR=$3

# ===== wp-config.php 에서 DB 정보 추출 =====
DB_NAME=$(grep "DB_NAME" ${WP_CONFIG} | sed "s/.*'DB_NAME', *'//" | sed "s/'.*//")
DB_USER=$(grep "DB_USER" ${WP_CONFIG} | sed "s/.*'DB_USER', *'//" | sed "s/'.*//")
DB_PASS=$(grep "DB_PASSWORD" ${WP_CONFIG} | sed "s/.*'DB_PASSWORD', *'//" | sed "s/'.*//")

step_header "마이그레이션 정보"
echo ""
info "DB_NAME : ${DB_NAME}"
info "DB_USER : ${DB_USER}"
info "DB_PASS : ${DB_PASS:0:4}****"
info "RDS     : ${RDS_ADDR}"
info "리전    : ${AWS_REGION}"


########################################
# 1단계: 사전 준비
########################################
step_header "[1/6] 사전 준비 — 백업 디렉토리 및 SSL 인증서"

# 백업 디렉토리 생성
mkdir -p ${BACKUP_DIR}
ok "백업 디렉토리: ${BACKUP_DIR}"

# SSL 인증서 다운로드
info "SSL 인증서 다운로드 중..."
wget -q -O ${SSL_PEM} \
    https://truststore.pki.rds.amazonaws.com/${AWS_REGION}/${AWS_REGION}-bundle.pem

if [ $? -ne 0 ]; then
    fail "SSL 인증서 다운로드 실패"
    exit 1
fi
ok "SSL 인증서: ${SSL_PEM}"


########################################
# 2단계: 로컬 DB 접속 테스트
########################################
step_header "[2/6] 로컬 DB 접속 테스트"

info "로컬 MySQL 접속 시도..."
LOCAL_TEST=$(mysql -u root -p${LOCAL_ROOT_PW} -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" -s -N 2>/dev/null)

if [ $? -eq 0 ]; then
    ok "로컬 DB 접속 성공"
    ok "테이블 수: ${LOCAL_TEST}개"
else
    fail "로컬 DB 접속 실패"
    fail "${LOCAL_TEST}"
    exit 1
fi


########################################
# 3단계: RDS 접속 테스트
########################################
step_header "[3/6] RDS 접속 테스트"

info "RDS 접속 시도 (SSL)..."

# 백그라운드에서 RDS 접속 테스트 실행
RDS_RESULT_FILE=$(mktemp)
(mysql -u admin -p${RDS_ADMIN_PW} \
    --host=${RDS_ADDR} --port=3306 \
    ${SSL_OPTS} \
    -e "SELECT VERSION();" -s -N 2>/dev/null > ${RDS_RESULT_FILE}; echo $? > ${RDS_RESULT_FILE}.rc) &
RDS_PID=$!

# 5초 카운트다운 (1초 간격)
TIMEOUT_HIT=false
for i in 5 4 3 2 1; do
    if ! kill -0 ${RDS_PID} 2>/dev/null; then
        break
    fi
    info "RDS 응답 대기 중... ${i}초"
    sleep 1
done

# 5초 경과 후에도 아직 실행 중이면 보안그룹 안내
if kill -0 ${RDS_PID} 2>/dev/null; then
    TIMEOUT_HIT=true
    echo ""
    fail "RDS 접속이 5초 이상 걸리고 있습니다!"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}  ⚠  보안 그룹 설정을 확인하세요!${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}  RDS 인스턴스에 'default' 보안 그룹을 추가하세요.${NC}"
    echo -e "  ${YELLOW}  (이 EC2의 IP에서 3306 포트 인바운드 허용 필요)${NC}"
    echo ""
    info "접속 시도를 계속 대기합니다... (Ctrl+C로 중단)"
fi

# 백그라운드 프로세스 완료 대기
wait ${RDS_PID} 2>/dev/null
RDS_RC=$(cat ${RDS_RESULT_FILE}.rc 2>/dev/null)
RDS_TEST=$(cat ${RDS_RESULT_FILE} 2>/dev/null)
rm -f ${RDS_RESULT_FILE} ${RDS_RESULT_FILE}.rc

if [ "${RDS_RC}" = "0" ]; then
    ok "RDS 접속 성공"
    ok "RDS 버전: ${RDS_TEST}"
else
    fail "RDS 접속 실패"
    fail "${RDS_TEST}"
    fail "보안 그룹, 엔드포인트 주소, admin 비밀번호를 확인하세요"
    exit 1
fi


########################################
# 4단계: 백업 및 DB 덤프
########################################
step_header "[4/6] 파일 백업 및 로컬 DB 덤프"

# wp-config.php 백업
cp ${WP_CONFIG} ${BACKUP_DIR}/wp-config.php.bak
ok "wp-config.php 백업 완료"

# 로컬 DB 덤프 파일 생성
DUMP_FILE=${BACKUP_DIR}/${DB_NAME}_dump.sql
info "DB 덤프 생성 중... (시간이 걸릴 수 있습니다)"

mysqldump -u root \
    --databases ${DB_NAME} \
    --single-transaction \
    --order-by-primary \
    -p${LOCAL_ROOT_PW} 2>/dev/null > ${DUMP_FILE}

if [ $? -ne 0 ]; then
    fail "DB 덤프 실패"
    exit 1
fi

# MariaDB 전용 구문 → MySQL 호환으로 변환
info "MariaDB → MySQL 호환성 변환 중..."
sed -i '/\/\*M!999999.*sandbox mode/d' ${DUMP_FILE}
sed -i '/\/\*M!100616/d' ${DUMP_FILE}
sed -i 's/utf8mb4_uca1400_ai_ci/utf8mb4_unicode_ci/g' ${DUMP_FILE}
ok "sandbox mode 주석 제거"
ok "MariaDB 전용 조건부 주석 제거"
ok "collation 변환 완료 (utf8mb4_uca1400_ai_ci → utf8mb4_unicode_ci)"

DUMP_SIZE=$(du -h ${DUMP_FILE} | awk '{print $1}')
ok "덤프 파일: ${DUMP_FILE} (${DUMP_SIZE})"


########################################
# 5단계: RDS로 데이터 전송 및 계정 설정
########################################
step_header "[5/6] RDS 마이그레이션 — 데이터 전송 및 계정 설정"

# 덤프 파일 → RDS 전송
info "덤프 파일 → RDS 전송 중... (시간이 걸릴 수 있습니다)"
mysql -u admin \
    --port=3306 \
    --host=${RDS_ADDR} \
    -p${RDS_ADMIN_PW} \
    ${SSL_OPTS} < ${DUMP_FILE} 2>/dev/null

if [ $? -ne 0 ]; then
    fail "RDS 전송 실패"
    exit 1
fi
ok "데이터 전송 완료"

# RDS에 WordPress DB 사용자 생성
info "RDS에 사용자 '${DB_USER}' 생성 중..."
mysql --host=${RDS_ADDR} --port=3306 \
    -u admin -p${RDS_ADMIN_PW} \
    ${SSL_OPTS} \
    -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}'; \
        GRANT ALL ON ${DB_NAME}.* TO '${DB_USER}'@'%'; \
        FLUSH PRIVILEGES;" 2>/dev/null

if [ $? -ne 0 ]; then
    fail "사용자 생성 실패"
    exit 1
fi
ok "사용자 '${DB_USER}' 생성 및 권한 부여 완료"

# wp-config.php 의 DB_HOST를 RDS 엔드포인트로 변경
info "wp-config.php DB_HOST 변경..."
WP_TMP=$(mktemp)
sed "s/define( *'DB_HOST'.*/define( 'DB_HOST', '${RDS_ADDR}:3306' );/" ${WP_CONFIG} > ${WP_TMP} && cp ${WP_TMP} ${WP_CONFIG} && rm -f ${WP_TMP}
ok "DB_HOST → ${RDS_ADDR}:3306"

# RDS MySQL 8.4 대응: WordPress(PHP)도 RDS에 SSL로 접속하도록 설정
if ! grep -q "MYSQL_CLIENT_FLAGS" ${WP_CONFIG}; then
    if grep -q "That's all, stop editing" ${WP_CONFIG}; then
        sed -i "/That's all, stop editing/i define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL );\n" ${WP_CONFIG}
    else
        sed -i "/require_once.*wp-settings\.php/i define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL );\n" ${WP_CONFIG}
    fi
fi
if grep -q "MYSQL_CLIENT_FLAGS" ${WP_CONFIG}; then
    ok "MYSQL_CLIENT_FLAGS → MYSQLI_CLIENT_SSL (WordPress도 SSL로 접속)"
else
    fail "MYSQL_CLIENT_FLAGS 추가 실패 — wp-config.php에 직접 추가하세요"
fi


########################################
# 6단계: 최종 점검
########################################
step_header "[6/6] 최종 점검"

# [A] wp-config.php 설정 확인
echo ""
echo -e "  ${YELLOW}[ wp-config.php DB 설정 ]${NC}"
grep -E "DB_NAME|DB_USER|DB_PASSWORD|DB_HOST|MYSQL_CLIENT_FLAGS" ${WP_CONFIG} | while read line; do
    info "${line}"
done

# [B] 백업 파일 목록
echo ""
echo -e "  ${YELLOW}[ 백업 파일 목록 ]${NC}"
ls -lh ${BACKUP_DIR}/ | tail -n +2 | while read line; do
    info "${line}"
done

# [C] RDS 연결 테스트 (WordPress 계정으로)
echo ""
echo -e "  ${YELLOW}[ RDS 연결 테스트 — ${DB_USER} 계정 ]${NC}"
mysql --host=${RDS_ADDR} --port=3306 \
    -u ${DB_USER} -p${DB_PASS} \
    ${SSL_OPTS} \
    -e "SELECT 1;" ${DB_NAME} > /dev/null 2>&1

if [ $? -eq 0 ]; then
    ok "RDS 연결 성공 (${DB_USER})"
else
    fail "RDS 연결 실패 (${DB_USER})"
fi

# [D] RDS 테이블 수 비교
echo ""
echo -e "  ${YELLOW}[ 테이블 수 비교 ]${NC}"
RDS_TABLE_COUNT=$(mysql --host=${RDS_ADDR} --port=3306 \
    -u ${DB_USER} -p${DB_PASS} \
    ${SSL_OPTS} \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" -s -N 2>/dev/null)
info "로컬 DB : ${LOCAL_TEST}개"
info "RDS     : ${RDS_TABLE_COUNT}개"

if [ "${LOCAL_TEST}" = "${RDS_TABLE_COUNT}" ]; then
    ok "테이블 수 일치"
else
    fail "테이블 수 불일치 — 데이터 확인 필요"
fi

# [E] WordPress 사이트 응답 확인
echo ""
echo -e "  ${YELLOW}[ WordPress HTTP 응답 ]${NC}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ 2>/dev/null)
if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "301" ] || [ "${HTTP_CODE}" = "302" ]; then
    ok "HTTP 응답: ${HTTP_CODE}"
else
    fail "HTTP 응답: ${HTTP_CODE}"
    info "웹서버 재시작이 필요할 수 있습니다"
fi

# 결과 요약
step_header "마이그레이션 완료!"
echo ""
info "백업 위치: ${BACKUP_DIR}"
echo ""
echo -e "  ${YELLOW}문제 발생 시 복원:${NC}"
echo "    cp ${BACKUP_DIR}/wp-config.php.bak ${WP_CONFIG}"
echo ""
