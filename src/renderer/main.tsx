import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { installDemo, isDemo } from './console/demo'
import { SelfTestPage } from './selftest/SelfTestPage'
import './console/console.css'
import './legacy.css'
import './app.css'

const container = document.getElementById('root')
if (!container) throw new Error('Missing #root')

const params = new URLSearchParams(window.location.search)
const selftest = params.has('selftest')
if (isDemo) installDemo()

createRoot(container).render(<StrictMode>{selftest ? <SelfTestPage /> : <App />}</StrictMode>)
