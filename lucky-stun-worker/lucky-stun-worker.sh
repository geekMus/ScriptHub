#!/bin/sh
# ============================================================================
# lucky-stun-worker —— 把打洞端口部署进 Cloudflare Worker 的单文件脚本
#
# 它自己不带任何配置：需要的值全部从命令行参数（或同名环境变量）拿。
# domain / suffix 没有内置默认值，缺了就直接报「缺少参数」并以 exit 1 结束。
#
# 用法：
#   lucky-stun-worker.sh --token <TOKEN> --account <ACCOUNT_ID> \
#                        --domain <主域名> --suffix <跳转后缀> \
#                        --port <打洞端口> [--worker stun-redirect] \
#                        [--v6-suffix <后缀>] [--v6-port 100] [--dry-run]
#
# 参数（括号里是等价环境变量，命令行优先）：
#   --token        CF_WORKER_API_TOKEN   Cloudflare API Token（Workers Scripts:Edit）
#   --account      CF_ACCOUNT_ID         账户 ID
#   --domain       BASE_DOMAIN           主域名
#   --suffix       V4_SUFFIX             IPv4 跳转后缀
#   --port         port                  打洞得到的公网端口
#   --worker       WORKER_NAME           Worker 名称（默认 stun-redirect）
#   --v6-suffix    V6_SUFFIX             IPv6 后缀（默认同 --suffix）
#   --v6-port      V6_PORT               IPv6 端口（默认 100）
#   --dry-run                            只打印解析结果，不部署
#
# 在 Lucky 里用：把本文件放进容器（例如 /root/lucky/conf/ 挂载到 /app/conf/），
# 脚本框只写一行调用，端口用 Lucky 的 ${port} 占位符：
#   sh /app/conf/lucky-stun-worker.sh --token "..." --account "..." \
#      --domain "example.com" --suffix "rt.example.com" --port "${port}"
#
# 退出码（给 retry.sh 用）：
#   0   部署成功
#   75  临时失败：连不上 api.cloudflare.com、请求超时、CF 返回 5xx/429
#       —— 链路抖一下就能好，外层 retry.sh 只认这个码才会再试
#   1   配置/鉴权/参数错误，或 CF 明确拒绝（4xx）：重试没有意义
# ============================================================================

TOKEN="${CF_WORKER_API_TOKEN:-}"
ACCOUNT="${CF_ACCOUNT_ID:-}"
DOMAIN="${BASE_DOMAIN:-}"
SUFFIX="${V4_SUFFIX:-}"
V6S="${V6_SUFFIX:-}"
V6P="${V6_PORT:-100}"
WORKER="${WORKER_NAME:-stun-redirect}"
DRY_RUN=0

# Lucky 调用时会把 ${port} 整个替换成实际端口；命令行用 --port 覆盖
PORT="${port}"

# 每个带值的选项都先确认后面确实跟着一个参数：busybox ash 的 `shift 2` 在参数
# 不足时不会报错、也不会真正前移，会在这里变成死循环（N1 实测）。
need() { [ "$1" -ge 2 ] || { echo "❌ 参数 ${2} 后面缺少值（--help 看用法）" >&2; exit 1; }; }

while [ $# -gt 0 ]; do
    case "$1" in
        --token)     need $# "$1"; TOKEN="$2"; shift 2 ;;
        --account)   need $# "$1"; ACCOUNT="$2"; shift 2 ;;
        --domain)    need $# "$1"; DOMAIN="$2"; shift 2 ;;
        --suffix)    need $# "$1"; SUFFIX="$2"; shift 2 ;;
        --port)      need $# "$1"; PORT="$2"; shift 2 ;;
        --worker)    need $# "$1"; WORKER="$2"; shift 2 ;;
        --v6-suffix) need $# "$1"; V6S="$2"; shift 2 ;;
        --v6-port)   need $# "$1"; V6P="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "未知参数：$1（--help 看用法）" >&2; exit 1 ;;
    esac
done

[ -n "${V6S}" ] || V6S="${SUFFIX}"

# ------------------------------- 校验 -------------------------------
MISSING=""
[ -n "${TOKEN}" ]   || MISSING="${MISSING} --token"
[ -n "${ACCOUNT}" ] || MISSING="${MISSING} --account"
[ -n "${DOMAIN}" ]  || MISSING="${MISSING} --domain"
[ -n "${SUFFIX}" ]  || MISSING="${MISSING} --suffix"
[ -n "${PORT}" ]    || MISSING="${MISSING} --port"

if [ -n "${MISSING}" ]; then
    echo "❌ 缺少参数：${MISSING}" >&2
    echo "   --domain / --suffix / --port 没有默认值，必须自己传" >&2
    echo "   （也可以设环境变量 BASE_DOMAIN / V4_SUFFIX / port）" >&2
    echo "   用法：$0 --token ... --account ... --domain <主域名> --suffix <跳转后缀> --port <端口>" >&2
    exit 1
fi

case "${PORT}" in
    ''|*[!0-9]*|0) echo "❌ --port 不是合法端口：${PORT}" >&2; exit 1 ;;
esac

# ============================================================================
# Worker 代码（整份覆盖部署，端口等用上面的变量注入）
# ============================================================================

WORKER_CODE=$(cat <<EOF
const CONFIG = {
    baseDomain: '${DOMAIN}',
    ipv4: {
        suffix: '${SUFFIX}',
        port: ${PORT}
    },
    ipv6: {
        suffix: '${V6S}',
        port: ${V6P}
    }
};

addEventListener('fetch', event => {
    event.respondWith(handleRequest(event.request));
});

/**
 * 请求入口
 */
async function handleRequest(request) {
    try {
        const corsHeaders = buildCorsHeaders(request);

        // OPTIONS 预检
        if (request.method === 'OPTIONS') {
            return new Response(null, {
                status: 204,
                headers: corsHeaders
            });
        }

        const url = new URL(request.url);
        const subdomain = extractSubdomain(url.hostname);
        const networkConfig = getNetworkConfig(request);
        const targetUrl = buildRedirectUrl({
            originalUrl: url,
            subdomain,
            networkConfig
        });

        // 创建原始 307
        const redirectResponse = Response.redirect(targetUrl, 307);

        // 复制 Header
        const headers = new Headers(redirectResponse.headers);

        // 添加 CORS
        for (const [key, value] of Object.entries(corsHeaders)) {
            headers.set(key, value);
        }

        // 返回最终 307
        return new Response(null, {
            status: 307,
            headers
        });
    } catch (error) {
        return createErrorResponse(error, request);
    }
}

/**
 * 构建 CORS Header
 */
function buildCorsHeaders(request) {
    const origin = request.headers.get('Origin') || '*';

    return {
        'Access-Control-Allow-Origin': origin,
        'Access-Control-Allow-Credentials': 'true',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Max-Age': '86400',
        'Vary': 'Origin'
    };
}

/**
 * 提取子域名
 */
function extractSubdomain(hostname) {
    const normalized = hostname.toLowerCase();

    if (normalized === CONFIG.baseDomain) {
        return '';
    }

    const suffix = '.' + CONFIG.baseDomain;

    if (!normalized.endsWith(suffix)) {
        return '';
    }

    return normalized.slice(0, -suffix.length);
}

/**
 * 获取客户端 IP
 */
function getClientIP(request) {
    return request.headers.get('CF-Connecting-IP') || '';
}

/**
 * 判断是否为 IPv6
 */
function isIPv6Address(ip) {
    return ip.includes(':');
}

/**
 * 根据客户端 IP 获取网络配置
 */
function getNetworkConfig(request) {
    const clientIP = getClientIP(request);

    if (isIPv6Address(clientIP)) {
        return CONFIG.ipv6;
    }

    return CONFIG.ipv4;
}

/**
 * 构建目标域名
 */
function buildTargetDomain(subdomain, suffix) {
    if (!subdomain) {
        return suffix;
    }

    return subdomain + '.' + suffix;
}

/**
 * 构建跳转 URL
 */
function buildRedirectUrl({ originalUrl, subdomain, networkConfig }) {
    const targetDomain = buildTargetDomain(subdomain, networkConfig.suffix);

    return 'https://' + targetDomain + ':' + networkConfig.port + originalUrl.pathname + originalUrl.search;
}

/**
 * 创建错误响应
 */
function createErrorResponse(error, request) {
    return new Response(error.stack || error.toString(), {
        status: 500,
        headers: {
            'Content-Type': 'text/plain;charset=UTF-8',
            ...buildCorsHeaders(request)
        }
    });
}
EOF
)

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "worker   : ${WORKER}"
    echo "domain   : ${DOMAIN}"
    echo "ipv4     : ${SUFFIX}:${PORT}"
    echo "ipv6     : ${V6S}:${V6P}"
    echo "code size: $(printf '%s' "${WORKER_CODE}" | wc -c) bytes"
    exit 0
fi

# ============================================================================
# 部署 Worker（单次；需要重试请用 retry/retry.sh 包一层）
# ============================================================================

RESP=$(curl -sS --connect-timeout 2 --max-time 5 -w '\n%{http_code}' -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/workers/scripts/${WORKER}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/javascript" \
    --data "${WORKER_CODE}" 2>&1)
CURL_RC=$?

if [ "${CURL_RC}" -ne 0 ]; then
    echo "❌ 请求失败（curl 退出码 ${CURL_RC}）：连不上 api.cloudflare.com 或超时"
    printf '%s\n' "${RESP}" | sed '$d'
    echo "   属于临时失败（退出码 75），外层 retry.sh 会再试"
    exit 75
fi

# curl -w 把 HTTP 状态码追加在响应体最后一行，单独拆出来
HTTP=$(printf '%s\n' "${RESP}" | tail -n1)
BODY=$(printf '%s\n' "${RESP}" | sed '$d')

if printf '%s\n' "${BODY}" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    echo "✅ Worker 部署成功（${SUFFIX}:${PORT}）"
    exit 0
fi

case "${HTTP}" in
    429|5??)
        echo "❌ Worker 部署失败（HTTP ${HTTP}）：Cloudflare 侧临时错误或限流"
        printf '%s\n' "${BODY}"
        echo "   属于临时失败（退出码 75），外层 retry.sh 会再试"
        exit 75
        ;;
esac

echo "❌ Worker 部署失败（HTTP ${HTTP}）：参数/鉴权问题，重试没有意义"
printf '%s\n' "${BODY}"
exit 1