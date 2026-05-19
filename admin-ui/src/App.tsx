import { useAccount } from 'wagmi'
import { Header } from './components/Header'
import { ContractCard } from './components/ContractCard'
import { CONTRACTS } from './config/contracts'

export default function App() {
  const { isConnected } = useAccount()

  return (
    <div className="min-h-screen bg-gray-950">
      <Header />
      <main className="mx-auto max-w-7xl px-4 py-8">
        {!isConnected ? (
          <div className="flex flex-col items-center justify-center py-32 text-center">
            <div className="text-5xl mb-6">🔐</div>
            <h2 className="text-2xl font-semibold text-white mb-2">Fee Collector Admin</h2>
            <p className="text-gray-400">Connect your wallet to manage fee collector contracts.</p>
          </div>
        ) : (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            {CONTRACTS.map((contract) => (
              <ContractCard
                key={`${contract.chainId}_${contract.address}`}
                contract={contract}
              />
            ))}
          </div>
        )}
      </main>
    </div>
  )
}
