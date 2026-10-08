import { client } from '@/api/generated/client.gen'

function getCookie(name: string): string | undefined {
  return document.cookie
    .split('; ')
    .find((row) => row.startsWith(`${name}=`))
    ?.split('=')[1]
}

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS', 'TRACE'])

// Same-origin session auth: send cookies, and echo Django's CSRF token on unsafe methods.
client.setConfig({ baseUrl: '', credentials: 'same-origin' })

client.interceptors.request.use((request) => {
  if (!SAFE_METHODS.has(request.method)) {
    const token = getCookie('csrftoken')
    if (token) request.headers.set('X-CSRFToken', decodeURIComponent(token))
  }
  return request
})
