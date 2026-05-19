import { ConnectButton } from '@rainbow-me/rainbowkit'

export function Header() {
  return (
    <header className="border-b border-gray-800 bg-gray-900 px-6 py-4 sticky top-0 z-50">
      <div className="mx-auto flex max-w-7xl items-center justify-between">
        <div>
          <h1 className="text-lg font-bold text-white">Fee Collector Admin</h1>
          <p className="text-xs text-gray-500">Kasplex · IGRA · Zealous Swap</p>
        </div>
        <ConnectButton />
      </div>
    </header>
  )
}
