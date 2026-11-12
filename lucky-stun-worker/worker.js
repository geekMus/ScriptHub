const CONFIG = {
    baseDomain: 'mus.pp.ua',
    ipv4: {
        suffix: 'rt.mus.pp.ua',
        port: 6058
    },
    ipv6: {
        suffix: 'rt.mus.pp.ua',
        port: 100
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