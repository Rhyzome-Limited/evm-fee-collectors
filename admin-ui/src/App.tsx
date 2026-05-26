import { useAccount } from 'wagmi'
import { Header } from './components/Header'
import { ContractCard } from './components/ContractCard'
import { CONTRACTS } from './config/contracts'
import { kasplexMainnet, igraMainnet } from './config/chains'

const NETWORKS = [
  { id: kasplexMainnet.id, name: 'Kasplex zkEVM' },
  { id: igraMainnet.id, name: 'IGRA Mainnet' },
]

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
          <div className="space-y-10">
            {NETWORKS.map((network) => {
              const contracts = CONTRACTS.filter((c) => c.chainId === network.id)
              if (contracts.length === 0) return null
              return (
                <section key={network.id}>
                  <h2 className="text-lg font-semibold text-gray-300 mb-4 border-b border-gray-800 pb-2">
                    {network.name}
                  </h2>
                  <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                    {contracts.map((contract) => (
                      <ContractCard
                        key={`${contract.chainId}_${contract.address}`}
                        contract={contract}
                      />
                    ))}
                  </div>
                </section>
              )
            })}
          </div>
        )}
      </main>
    </div>
  )
}
