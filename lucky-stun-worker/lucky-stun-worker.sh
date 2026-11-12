#!/bin/sh
# ============================================================================
# Lucky STUN → Cloudflare Worker 端口同步脚本
#
# 用途：Lucky 的 STUN 穿透规则在公网端口变化后调用本脚本，把新端口写进
#       已经部署好的 Cloudflare Worker，让 <名字>.<主域名> 的 307 跳转
#       始终指向当前可用的端口。
#
# 用法：Lucky → STUN 穿透 → 规则 → 编辑 → “脚本/Webhook”整段粘贴本文件，
#       只需改下面四个空值。Lucky 会把 ${port} 替换成本次打洞的公网端口。
#
# 依赖：容器内只要 sh + curl + grep（Lucky 官方镜像自带）。
# 超时：Lucky 对每轮脚本有 15 秒硬超时，超时直接 SIGKILL（日志：signal: killed）；
#       本脚本最多 11 秒，留 4 秒余量。
# ============================================================================

# ------------------------------- 需要你改 -------------------------------
# Cloudflare API Token（权限：Workers Scripts:Edit，建议只授权这一个账号）
CF_WORKER_API_TOKEN=""
# Cloudflare 账户 ID
CF_ACCOUNT_ID=""
# 主域名（Worker 的路由挂在 *.<主域名> 上）
BASE_DOMAIN=""
# 跳转目标的后缀（例如 rt.mus.pp.ua）
V4_SUFFIX=""
# ------------------------------------------------------------------------

# Worker 名称，和 Cloudflare 上的脚本名一致即可
WORKER_NAME="stun-redirect"

# 端口：IPv4 由 Lucky 注入，不要手填；IPv6 固定 100
V4_PORT="${port}"
V6_SUFFIX="${V4_SUFFIX}"
V6_PORT=100

# ------------------------------- 前置检查 -------------------------------
# 填错配置会部署出一个坏 Worker，宁可早退
if [ -z "${CF_WORKER_API_TOKEN}" ] || [ -z "${CF_ACCOUNT_ID}" ] || \
   [ -z "${BASE_DOMAIN}" ] || [ -z "${V4_SUFFIX}" ]; then
    echo "❌ 配置不完整：请先填 CF_WORKER_API_TOKEN / CF_ACCOUNT_ID / BASE_DOMAIN / V4_SUFFIX"
    exit 1
fi

# 手动测试时 ${port} 为空，不能把 0 部署上去
if [ -z "${V4_PORT}" ] || [ "${V4_PORT}" = "0" ]; then
    echo "❌ 没有拿到打洞端口（\${port} 为空）——通常是规则还没打通就触发了脚本"
    exit 1
fi

# ============================================================================
# Worker 代码（整份覆盖部署，端口用上面的变量注入）
# ============================================================================

WORKER_CODE=$(cat <<EOF
const CONFIG = {
    baseDomain: '${BASE_DOMAIN}',
    ipv4: {
        suffix: '${V4_SUFFIX}',
        port: ${V4_PORT}
    },
    ipv6: {
        suffix: '${V6_SUFFIX}',
        port: ${V6_PORT}
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

# ============================================================================
# 部署 Worker（最多 3 次；Lucky 的硬超时是 15 秒，这里最坏 11 秒）
# ============================================================================

DEPLOY_OK=0
TRY=1
while [ "${TRY}" -le 3 ]; do
    RESULT=$(curl -s --connect-timeout 2 --max-time 3 -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
        -H "Authorization: Bearer ${CF_WORKER_API_TOKEN}" \
        -H "Content-Type: application/javascript" \
        --data "${WORKER_CODE}")

    if echo "${RESULT}" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        DEPLOY_OK=1
        break
    fi

    if [ "${TRY}" -lt 3 ]; then
        echo "⚠️ 第 ${TRY} 次部署失败，1 秒后重试"
        sleep 1
    fi
    TRY=$((TRY + 1))
done

if [ "${DEPLOY_OK}" -eq 1 ]; then
    echo "✅ Worker 部署成功（${V4_PORT}）"
else
    echo "❌ Worker 部署失败"
    echo "${RESULT}"
fi
