#!/bin/bash
#
# AMI로 새 EC2 인스턴스를 띄운 뒤 WordPress를 바로 쓸 수 있게 맞춰주는 스크립트
# (Mindglow "Quick Setup WordPress on Ubuntu" + RDS MySQL 8.4 + S3(WP Offload Media) 실습 환경)
#
# 사용법 (둘 중 하나)
#   1) SSH 접속 후 직접 실행
#        wget https://github.com/Hawordkim/cocoo/raw/refs/heads/main/ami-setup.sh
#        sudo bash ami-setup.sh
#
#   2) 인스턴스를 만들 때 자동 실행
#      EC2 시작 화면 → 고급 세부 정보 → 사용자 데이터에 아래 2줄 입력
#        #!/bin/bash
#        curl -sL https://github.com/Hawordkim/cocoo/raw/refs/heads/main/ami-setup.sh | bash
#      (실행 결과는 인스턴스 안의 /var/log/cloud-init-output.log 에 남음)
#
# 하는 일 (여러 번 실행해도 안전 — 이미 되어 있는 건 건너뜀)
#   1. wp-config.php: WP_HOME / WP_SITEURL을 "접속한 주소" 기준으로 설정
#                     → AMI로 새 인스턴스를 띄워 IP가 바뀌어도 바로 접속됨 (Bitnami 방식)
#   2. wp-config.php: DB가 RDS면 WordPress도 SSL로 접속 (MYSQL_CLIENT_FLAGS)
#   3. mu-plugin 설치: 글에 저장된 예전 인스턴스 주소의 이미지도 S3 주소로 표시
#                     → 새 글·새 이미지가 생겨도 주소 목록을 자동으로 다시 계산
#   4. 점검: IAM 역할, RDS 연결(보안그룹), WordPress 응답, 이미지 주소
#

# ===== 설정 =====
WP_DIR=${WP_DIR:-/var/www/html}
WP_CONFIG=${WP_DIR}/wp-config.php
BACKUP_DIR=/root/ami-setup-backup-$(date +%Y%m%d_%H%M%S)
MU_PLUGIN_NAME=cocoo-upload-hosts.php
OLD_MU_PLUGIN_NAME=as3cf-old-domains.php   # 예전에 손으로 만든 고정 목록 파일 (새 파일로 대체)

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
fail() { echo -e "  ${RED}✗${NC} $1"; WARN_COUNT=$((WARN_COUNT + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARN_COUNT=$((WARN_COUNT + 1)); }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

WARN_COUNT=0

# ===== 실행 권한 확인 =====
if [ "$(id -u)" -ne 0 ]; then
    echo "root 권한이 필요합니다. 이렇게 실행하세요: sudo bash $0"
    exit 1
fi

# ===== wp-config.php 위치 확인 =====
if [ ! -f "${WP_CONFIG}" ]; then
    FOUND=$(find /var/www -maxdepth 4 -name wp-config.php 2>/dev/null | head -n 1)
    if [ -n "${FOUND}" ]; then
        WP_CONFIG=${FOUND}
        WP_DIR=$(dirname "${FOUND}")
    else
        echo "wp-config.php를 찾을 수 없습니다. WP_DIR=/경로 bash $0 형식으로 지정하세요."
        exit 1
    fi
fi

# ===== 공통 함수 =====
# 주석이 아닌 define('NAME', ...) 줄이 있는지
has_define() {
    grep -Eq "^[[:space:]]*define\([[:space:]]*['\"]$1['\"]" "$2"
}

# define('NAME', '값') 에서 값 꺼내기
get_define() {
    grep -E "^[[:space:]]*define\([[:space:]]*['\"]$1['\"]" "${WP_CONFIG}" | head -n 1 \
        | sed -nE "s/.*['\"]$1['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p"
}

# "That's all, stop editing" 줄 바로 위에 텍스트 삽입 (없으면 wp-settings.php 줄 위)
insert_before_marker() {
    local file=$1 text=$2 mark=""
    if grep -q "That's all, stop editing" "${file}"; then
        mark="That's all, stop editing"
    elif grep -q "wp-settings.php" "${file}"; then
        mark="wp-settings.php"
    else
        return 1
    fi
    INSERT_TEXT="${text}" MARK="${mark}" awk '
        !done && index($0, ENVIRON["MARK"]) { print ENVIRON["INSERT_TEXT"]; print ""; done = 1 }
        { print }
    ' "${file}" > "${file}.new" && mv "${file}.new" "${file}"
}

# EC2 메타데이터 (IMDSv2)
IMDS_TOKEN=$(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null)
imds() {
    curl -s -f -m 3 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
        "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null
}


########################################
# 1단계: 환경 확인
########################################
step_header "[1/5] 환경 확인"

DB_NAME=$(get_define DB_NAME)
DB_HOST=$(get_define DB_HOST)
PUBLIC_IP=$(imds public-ipv4)
IAM_ROLE=$(imds iam/security-credentials/)

info "wp-config : ${WP_CONFIG}"
info "DB_NAME   : ${DB_NAME}"
info "DB_HOST   : ${DB_HOST}"
info "퍼블릭 IP : ${PUBLIC_IP:-(확인 불가)}"

if [ -n "${IAM_ROLE}" ]; then
    ok "IAM 역할: ${IAM_ROLE}"
else
    fail "IAM 역할이 없습니다 — S3(WP Offload Media)가 동작하지 않을 수 있어요"
    info "EC2 콘솔 → 인스턴스 선택 → 작업 → 보안 → IAM 역할 수정 → EMR_EC2_DefaultRole"
fi

DB_IS_RDS=false
case "${DB_HOST}" in
    *rds.amazonaws.com*) DB_IS_RDS=true; ok "DB: RDS 사용 중" ;;
    *) info "DB: 로컬 DB 사용 중 (아직 RDS로 마이그레이션 전)" ;;
esac


########################################
# 2단계: wp-config.php 설정
########################################
step_header "[2/5] wp-config.php 설정"

mkdir -p "${BACKUP_DIR}"
cp -p "${WP_CONFIG}" "${BACKUP_DIR}/wp-config.php.bak"
ok "백업: ${BACKUP_DIR}/wp-config.php.bak"

WP_TMP=$(mktemp)
cat "${WP_CONFIG}" > "${WP_TMP}"
CHANGED=false

# (1) WP_HOME / WP_SITEURL — 접속한 주소를 그대로 사이트 주소로
if has_define WP_HOME "${WP_TMP}"; then
    ok "WP_HOME 설정 이미 있음 — 그대로 둠"
else
    URL_BLOCK=$(cat <<'EOF'
/* 접속한 주소(퍼블릭 IP/DNS/ELB)로 사이트 주소 자동 설정 — Bitnami와 같은 방식 (ami-setup.sh) */
define( 'WP_HOME', 'http://' . ( $_SERVER['HTTP_HOST'] ?? 'localhost' ) );
define( 'WP_SITEURL', 'http://' . ( $_SERVER['HTTP_HOST'] ?? 'localhost' ) );
EOF
)
    if insert_before_marker "${WP_TMP}" "${URL_BLOCK}"; then
        ok "WP_HOME / WP_SITEURL 추가"
        CHANGED=true
    else
        fail "WP_HOME을 넣을 위치를 찾지 못했습니다 — 직접 추가하세요"
    fi
fi

# (2) MYSQL_CLIENT_FLAGS — RDS일 때만 WordPress도 SSL로 접속
if [ "${DB_IS_RDS}" = true ]; then
    if has_define MYSQL_CLIENT_FLAGS "${WP_TMP}"; then
        ok "MYSQL_CLIENT_FLAGS 설정 이미 있음 — 그대로 둠"
    else
        if insert_before_marker "${WP_TMP}" "define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL );"; then
            ok "MYSQL_CLIENT_FLAGS → MYSQLI_CLIENT_SSL 추가 (WordPress도 RDS에 SSL로 접속)"
            CHANGED=true
        else
            fail "MYSQL_CLIENT_FLAGS를 넣을 위치를 찾지 못했습니다 — 직접 추가하세요"
        fi
    fi
else
    info "로컬 DB라서 MYSQL_CLIENT_FLAGS는 건너뜀 (RDS 마이그레이션 후 다시 실행하면 추가됨)"
fi

# 문법 검사 후 적용 (원래 소유자/권한 유지)
if [ "${CHANGED}" = true ]; then
    if command -v php >/dev/null 2>&1 && ! php -l "${WP_TMP}" >/dev/null 2>&1; then
        fail "수정한 wp-config.php에 PHP 문법 오류가 있어 적용하지 않았습니다"
        php -l "${WP_TMP}" 2>&1 | head -n 3 | sed 's/^/      /'
    else
        cat "${WP_TMP}" > "${WP_CONFIG}"
        ok "wp-config.php 저장 완료"
    fi
else
    ok "바꿀 것 없음"
fi
rm -f "${WP_TMP}"


########################################
# 3단계: S3 이미지 주소 자동 인식 플러그인
########################################
step_header "[3/5] S3 이미지 주소 자동 인식 (mu-plugin)"

MU_DIR=${WP_DIR}/wp-content/mu-plugins
MU_FILE=${MU_DIR}/${MU_PLUGIN_NAME}
WP_OWNER=$(stat -c '%U:%G' "${WP_DIR}/wp-content" 2>/dev/null || echo "www-data:www-data")

if [ ! -d "${WP_DIR}/wp-content/plugins/amazon-s3-and-cloudfront" ]; then
    warn "WP Offload Media 플러그인이 없습니다 — 그래도 파일은 설치해 둡니다 (플러그인이 없으면 아무 일도 안 함)"
fi

mkdir -p "${MU_DIR}"
cat > "${MU_FILE}.new" <<'PHPEOF'
<?php
/**
 * Plugin Name: cocoo - 업로드 이미지 주소 자동 인식 (WP Offload Media)
 * Description: 글 본문에 저장된 예전 인스턴스 주소(EC2 IP/DNS 등)의 업로드 이미지도 S3 주소로 바꿔서 보여줌.
 *              AMI로 새 인스턴스를 띄워 주소가 바뀌어도, 새 글/새 이미지가 생겨도 자동으로 동작. (ami-setup.sh가 설치)
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * 글 본문에 들어 있는 "…/wp-content/uploads/" 주소들의 호스트 목록 (S3·CloudFront 주소는 제외).
 * DB 조회 결과는 10분 동안 캐시하고, 글을 저장하면 바로 다시 계산.
 */
function cocoo_upload_hosts() {
	$hosts = get_transient( 'cocoo_upload_hosts' );
	if ( is_array( $hosts ) ) {
		return $hosts;
	}

	global $wpdb;
	$found = array();
	$like  = '%' . $wpdb->esc_like( '/wp-content/uploads/' ) . '%';
	$rows  = $wpdb->get_col( $wpdb->prepare( "SELECT post_content FROM {$wpdb->posts} WHERE post_content LIKE %s", $like ) );

	foreach ( (array) $rows as $content ) {
		if ( preg_match_all( '#(?:https?:)?//([a-z0-9.\-]+(?::[0-9]+)?)/wp-content/uploads/#i', $content, $m ) ) {
			foreach ( $m[1] as $host ) {
				$found[ strtolower( $host ) ] = true;
			}
		}
	}

	$hosts = array();
	foreach ( array_keys( $found ) as $host ) {
		// S3 / CloudFront 주소는 원래 원격 주소이므로 제외
		if ( preg_match( '/(^|\.)s3[.\-]|cloudfront\.net$/i', $host ) ) {
			continue;
		}
		$hosts[] = $host;
	}

	set_transient( 'cocoo_upload_hosts', $hosts, 10 * MINUTE_IN_SECONDS );
	return $hosts;
}

// WP Offload Media에게 "이 주소들도 우리 사이트 주소"라고 알려줌 → S3 주소로 바꿔서 출력
add_filter( 'as3cf_local_domains', function ( $domains ) {
	return array_values( array_unique( array_merge( (array) $domains, cocoo_upload_hosts() ) ) );
} );

// 글을 저장하면 주소 목록을 다시 계산
add_action( 'save_post', function () {
	delete_transient( 'cocoo_upload_hosts' );
} );
PHPEOF

if command -v php >/dev/null 2>&1 && ! php -l "${MU_FILE}.new" >/dev/null 2>&1; then
    fail "mu-plugin 문법 오류 — 설치하지 않았습니다"
    rm -f "${MU_FILE}.new"
else
    if [ -f "${MU_FILE}" ] && cmp -s "${MU_FILE}" "${MU_FILE}.new"; then
        rm -f "${MU_FILE}.new"
        ok "mu-plugin 이미 최신: ${MU_FILE}"
    else
        mv "${MU_FILE}.new" "${MU_FILE}"
        ok "mu-plugin 설치: ${MU_FILE}"
    fi
    chown "${WP_OWNER}" "${MU_DIR}" "${MU_FILE}" 2>/dev/null
    chmod 755 "${MU_DIR}"
    chmod 644 "${MU_FILE}"
fi

if [ -f "${MU_DIR}/${OLD_MU_PLUGIN_NAME}" ]; then
    mv "${MU_DIR}/${OLD_MU_PLUGIN_NAME}" "${BACKUP_DIR}/"
    ok "예전 고정 목록 파일(${OLD_MU_PLUGIN_NAME})은 새 파일로 대체 — 백업 폴더로 이동"
fi


########################################
# 4단계: RDS 연결 확인
########################################
step_header "[4/5] DB 연결 확인"

if [ "${DB_IS_RDS}" = true ]; then
    RDS_HOST=${DB_HOST%%:*}
    RDS_PORT=${DB_HOST##*:}
    [ "${RDS_PORT}" = "${DB_HOST}" ] && RDS_PORT=3306

    if timeout 5 bash -c "</dev/tcp/${RDS_HOST}/${RDS_PORT}" 2>/dev/null; then
        ok "RDS ${RDS_HOST}:${RDS_PORT} 포트 연결 OK"
    else
        fail "RDS 포트에 연결되지 않습니다 — 보안 그룹 문제"
        info "이 EC2 인스턴스에 'default' 보안 그룹을 추가하세요 (작업 → 보안 → 보안 그룹 변경)"
    fi
else
    info "로컬 DB 사용 중 — RDS 확인은 건너뜀"
fi


########################################
# 5단계: WordPress 응답 및 이미지 주소 확인
########################################
step_header "[5/5] WordPress 응답 및 이미지 주소 확인"

BODY=$(mktemp)
HTTP_CODE=000
# 부팅 직후(사용자 데이터로 실행)에는 웹서버가 늦게 뜰 수 있어서 최대 60초 대기
for i in $(seq 1 12); do
    HTTP_CODE=$(curl -s -o "${BODY}" -w "%{http_code}" -m 30 http://127.0.0.1/ 2>/dev/null)
    [ "${HTTP_CODE}" != "000" ] && break
    sleep 5
done

if grep -q "Error establishing a database connection" "${BODY}" 2>/dev/null; then
    fail "WordPress: 데이터베이스 연결 오류 (HTTP ${HTTP_CODE})"
    info "확인: 보안 그룹(4단계), wp-config.php의 DB_USER/DB_PASSWORD, RDS 상태"
elif [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "301" ] || [ "${HTTP_CODE}" = "302" ]; then
    ok "WordPress 응답: HTTP ${HTTP_CODE}"
else
    fail "WordPress 응답: HTTP ${HTTP_CODE}"
    info "웹서버 재시작: sudo systemctl restart apache2 (또는 nginx, php*-fpm)"
fi

# 첫 화면 + 최근 글(RSS 피드 본문)의 업로드 이미지 주소 분류
# (테마에 따라 첫 화면에는 요약만 나와서 이미지가 없을 수 있음)
curl -s -m 30 "http://127.0.0.1/?feed=rss2" >> "${BODY}" 2>/dev/null
IMG_URLS=$(grep -oE '(src|srcset)="[^"]+"' "${BODY}" 2>/dev/null \
    | grep -oE 'https?://[^" ,]+\.(jpg|jpeg|png|gif|webp)' \
    | grep -E '/wp-content/uploads/|\.s3[.-]|s3\.|cloudfront\.net' | sort -u)

if [ -z "${IMG_URLS}" ]; then
    info "첫 화면과 최근 글에 업로드 이미지가 없어서 이미지 확인은 건너뜀"
else
    S3_N=0; LOCAL_N=0; OTHER_N=0
    while IFS= read -r url; do
        host=$(echo "${url}" | sed -E 's#^https?://([^/]+)/.*#\1#')
        if echo "${host}" | grep -qiE '(^|\.)s3[.-]|cloudfront\.net$'; then
            S3_N=$((S3_N + 1))
        elif [ "${host}" = "127.0.0.1" ]; then
            LOCAL_N=$((LOCAL_N + 1))
            path=${url#*/wp-content/uploads/}
            if [ -f "${WP_DIR}/wp-content/uploads/${path}" ]; then
                info "서버에 있는 이미지 (아직 S3로 안 올라감): ${url}"
            else
                fail "이미지 파일이 서버에도 없고 S3 주소로도 안 바뀜: ${url}"
                info "WP Offload Media 설정 / IAM 역할을 확인하세요"
            fi
        else
            OTHER_N=$((OTHER_N + 1))
            fail "다른 주소를 가리키는 이미지: ${url}"
        fi
    done <<< "${IMG_URLS}"
    [ "${S3_N}" -gt 0 ] && ok "S3 주소로 나오는 이미지: ${S3_N}개"
    [ "${OTHER_N}" -gt 0 ] && info "다른 주소 이미지가 있으면 몇 분 뒤(목록 캐시 10분) 다시 실행해 보세요"
fi
rm -f "${BODY}"


# ===== 결과 요약 =====
step_header "완료!"
echo ""
if [ -n "${PUBLIC_IP}" ]; then
    info "접속 주소: http://${PUBLIC_IP}/"
fi
info "백업 위치: ${BACKUP_DIR}"
if [ "${WARN_COUNT}" -eq 0 ]; then
    ok "모든 점검 통과"
else
    echo -e "  ${YELLOW}확인이 필요한 항목: ${WARN_COUNT}개 (위의 ✗ / ! 표시)${NC}"
fi
echo ""
echo -e "  ${YELLOW}문제 발생 시 wp-config.php 복원:${NC}"
echo "    sudo cp ${BACKUP_DIR}/wp-config.php.bak ${WP_CONFIG}"
echo ""
