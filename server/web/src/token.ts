const TOKEN_KEY = 'checkcheck.token'

export const loadToken = () => localStorage.getItem(TOKEN_KEY)
export const saveToken = (token: string) => localStorage.setItem(TOKEN_KEY, token)
export const clearToken = () => localStorage.removeItem(TOKEN_KEY)
