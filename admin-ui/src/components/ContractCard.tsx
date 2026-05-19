import { useEffect, useState } from 'react'
import {
  useReadContracts,
  useBalance,
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
  useSwitchChain,
} from 'wagmi'
import { formatEther, formatUnits, isAddress } from 'viem'
import { feeCollectorAbi } from '../abi/feeCollectorAbi'
import { CHAIN_NAMES } from '../config/chains'
import type { ContractConfig } from '../config/contracts'

// ─── Minimal ERC-20 ABI ────────────────────────────────────────────────────────
const erc20Abi = [
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'symbol',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'string' }],
  },
  {
    name: 'decimals',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint8' }],
  },
] as const

// ─── Helpers ──────────────────────────────────────────────────────────────────
const ZERO = '0x0000000000000000000000000000000000000000'

function shorten(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

function eq(a?: string, b?: string) {
  if (!a || !b) return false
  return a.toLowerCase() === b.toLowerCase()
}

// ─── TokenRow ─────────────────────────────────────────────────────────────────
function TokenRow({
  tokenAddr,
  contractAddr,
  chainId,
  canWithdraw,
  onWithdrawAll,
  disabled,
}: {
  tokenAddr: `0x${string}`
  contractAddr: `0x${string}`
  chainId: number
  canWithdraw: boolean
  onWithdrawAll: (t: `0x${string}`) => void
  disabled: boolean
}) {
  const { data } = useReadContracts({
    contracts: [
      { address: tokenAddr, abi: erc20Abi, functionName: 'symbol', chainId },
      { address: tokenAddr, abi: erc20Abi, functionName: 'decimals', chainId },
      {
        address: tokenAddr,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [contractAddr],
        chainId,
      },
    ],
  })

  const symbol = (data?.[0].result as string | undefined) ?? '???'
  const decimals = (data?.[1].result as number | undefined) ?? 18
  const balance = (data?.[2].result as bigint | undefined) ?? 0n
  const balFmt = parseFloat(formatUnits(balance, decimals)).toFixed(4)

  return (
    <div className="flex items-center justify-between py-2 text-sm border-b border-gray-800 last:border-0">
      <div className="flex items-center gap-3 min-w-0">
        <span className="font-mono text-xs text-gray-500 truncate">{shorten(tokenAddr)}</span>
        <span className="text-white">
          {balFmt}{' '}
          <span className="text-gray-400 text-xs">{symbol}</span>
        </span>
      </div>
      {canWithdraw && (
        <button
          onClick={() => onWithdrawAll(tokenAddr)}
          disabled={balance === 0n || disabled}
          className="ml-2 px-2 py-1 text-xs rounded bg-emerald-800 hover:bg-emerald-700 disabled:opacity-40 shrink-0"
        >
          Withdraw All
        </button>
      )}
    </div>
  )
}

// ─── InfoRow ──────────────────────────────────────────────────────────────────
function InfoRow({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <p className="text-xs text-gray-500 mb-0.5">{label}</p>
      <p className={`text-sm text-white truncate ${mono ? 'font-mono' : ''}`}>{value}</p>
    </div>
  )
}

// ─── ActionRow ────────────────────────────────────────────────────────────────
function ActionRow({
  label,
  placeholder,
  hint,
  value,
  onChange,
  btnLabel,
  onSubmit,
  disabled,
  loading,
  danger = false,
}: {
  label: string
  placeholder: string
  hint?: string
  value: string
  onChange: (v: string) => void
  btnLabel: string
  onSubmit: () => void
  disabled: boolean
  loading: boolean
  danger?: boolean
}) {
  return (
    <div>
      <label className="text-xs text-gray-400 mb-1 block">{label}</label>
      <div className="flex gap-2">
        <input
          type="text"
          placeholder={placeholder}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className="flex-1 px-3 py-1.5 text-sm rounded bg-gray-800 border border-gray-700 text-white placeholder-gray-600 focus:outline-none focus:border-gray-500"
        />
        <button
          onClick={onSubmit}
          disabled={disabled}
          className={`px-3 py-1.5 text-sm rounded disabled:opacity-40 transition-colors ${
            danger
              ? 'bg-red-900 hover:bg-red-800'
              : 'bg-yellow-800 hover:bg-yellow-700'
          }`}
        >
          {loading ? '…' : btnLabel}
        </button>
      </div>
      {hint && <p className="text-xs text-gray-600 mt-1">{hint}</p>}
    </div>
  )
}

// ─── ContractCard ─────────────────────────────────────────────────────────────
export function ContractCard({ contract }: { contract: ContractConfig }) {
  const { address: userAddr, chainId: walletChainId } = useAccount()
  const { switchChain } = useSwitchChain()
  const { writeContractAsync } = useWriteContract()

  // ── Form state ──────────────────────────────────────────────────────────────
  const [feeRateInput, setFeeRateInput] = useState('')
  const [withdrawerInput, setWithdrawerInput] = useState('')
  const [ownerInput, setOwnerInput] = useState('')
  const [tokenInput, setTokenInput] = useState('')

  const [watchedTokens, setWatchedTokens] = useState<`0x${string}`[]>(() => {
    try {
      const saved = localStorage.getItem(`tokens_${contract.address}`)
      return saved ? (JSON.parse(saved) as `0x${string}`[]) : []
    } catch {
      return []
    }
  })

  // ── Tx state ────────────────────────────────────────────────────────────────
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>()
  const [pendingLabel, setPendingLabel] = useState('')
  const [txError, setTxError] = useState('')

  const { isLoading: isConfirming, isSuccess: isConfirmed } =
    useWaitForTransactionReceipt({ hash: txHash })

  // ── Read contract state ──────────────────────────────────────────────────────
  const { data: contractData, refetch } = useReadContracts({
    contracts: [
      { address: contract.address, abi: feeCollectorAbi, functionName: 'owner', chainId: contract.chainId },
      { address: contract.address, abi: feeCollectorAbi, functionName: 'pendingOwner', chainId: contract.chainId },
      { address: contract.address, abi: feeCollectorAbi, functionName: 'withdrawer', chainId: contract.chainId },
      { address: contract.address, abi: feeCollectorAbi, functionName: 'feeRate', chainId: contract.chainId },
    ],
  })

  const owner = contractData?.[0].result as `0x${string}` | undefined
  const pendingOwner = contractData?.[1].result as `0x${string}` | undefined
  const withdrawer = contractData?.[2].result as `0x${string}` | undefined
  const feeRate = contractData?.[3].result as bigint | undefined

  const { data: nativeBal, refetch: refetchBal } = useBalance({
    address: contract.address,
    chainId: contract.chainId,
  })

  // ── Refetch after confirmation ───────────────────────────────────────────────
  useEffect(() => {
    if (isConfirmed) {
      void refetch()
      void refetchBal()
      const t = setTimeout(() => {
        setTxHash(undefined)
        setPendingLabel('')
      }, 6000)
      return () => clearTimeout(t)
    }
  }, [isConfirmed, refetch, refetchBal])

  // ── Role detection ───────────────────────────────────────────────────────────
  const isOwner = eq(userAddr, owner)
  const isPendingOwner =
    !!pendingOwner &&
    pendingOwner !== ZERO &&
    eq(userAddr, pendingOwner)
  const isWithdrawer = eq(userAddr, withdrawer)
  const canWithdraw = isOwner || isWithdrawer

  const isWrongChain = !!userAddr && walletChainId !== contract.chainId
  const isBusy = isConfirming
  const isDeployed = contract.address !== ZERO

  const chainName = CHAIN_NAMES[contract.chainId] ?? `Chain ${contract.chainId}`

  // ── Execute helper ───────────────────────────────────────────────────────────
  const execute = async (label: string, fn: () => Promise<`0x${string}`>) => {
    if (!userAddr) return
    setTxError('')
    setPendingLabel(label)
    try {
      const hash = await fn()
      setTxHash(hash)
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Transaction failed'
      setTxError(msg.length > 160 ? msg.slice(0, 160) + '…' : msg)
      setPendingLabel('')
    }
  }

  // ── Token helpers ────────────────────────────────────────────────────────────
  const addToken = () => {
    if (!isAddress(tokenInput)) return
    const addr = tokenInput as `0x${string}`
    if (watchedTokens.some((t) => t.toLowerCase() === addr.toLowerCase())) return
    const next = [...watchedTokens, addr]
    setWatchedTokens(next)
    localStorage.setItem(`tokens_${contract.address}`, JSON.stringify(next))
    setTokenInput('')
  }

  const removeToken = (addr: `0x${string}`) => {
    const next = watchedTokens.filter((t) => t.toLowerCase() !== addr.toLowerCase())
    setWatchedTokens(next)
    localStorage.setItem(`tokens_${contract.address}`, JSON.stringify(next))
  }

  // ── Role badge ───────────────────────────────────────────────────────────────
  const roleBadge = isOwner ? (
    <span className="px-2 py-0.5 text-xs rounded bg-yellow-900 text-yellow-300">Owner</span>
  ) : isPendingOwner ? (
    <span className="px-2 py-0.5 text-xs rounded bg-orange-900 text-orange-300">Pending Owner</span>
  ) : isWithdrawer ? (
    <span className="px-2 py-0.5 text-xs rounded bg-blue-900 text-blue-300">Withdrawer</span>
  ) : userAddr ? (
    <span className="px-2 py-0.5 text-xs rounded bg-gray-800 text-gray-500">No role</span>
  ) : null

  const nativeFmt = nativeBal
    ? `${parseFloat(formatEther(nativeBal.value)).toFixed(4)} ${contract.symbol}`
    : '…'

  return (
    <div className="rounded-xl border border-gray-800 bg-gray-900 overflow-hidden flex flex-col">
      {/* ── Header ── */}
      <div className="px-5 py-4 border-b border-gray-800 bg-gray-900/80">
        <div className="flex items-center gap-2 flex-wrap mb-1">
          <h2 className="font-semibold text-white">{contract.label}</h2>
          <span className="px-2 py-0.5 text-xs rounded bg-gray-800 text-gray-400">{chainName}</span>
          <span className="px-2 py-0.5 text-xs rounded bg-gray-800 text-gray-400">
            {contract.type}
          </span>
          {roleBadge}
        </div>
        <a
          href={`${contract.explorerUrl}/address/${contract.address}`}
          target="_blank"
          rel="noreferrer"
          className="font-mono text-xs text-gray-500 hover:text-blue-400 transition-colors break-all"
        >
          {contract.address}
        </a>
      </div>

      {!isDeployed ? (
        <div className="flex-1 flex items-center justify-center py-12 text-center">
          <div>
            <div className="text-3xl mb-3">⚠️</div>
            <p className="text-sm text-gray-500">Contract address not configured</p>
            <p className="text-xs text-gray-600 mt-1">Edit src/config/contracts.ts</p>
          </div>
        </div>
      ) : (
        <div className="divide-y divide-gray-800 flex-1">
          {/* ── Contract State ── */}
          <div className="px-5 py-4 grid grid-cols-2 gap-4">
            <InfoRow
              label="Fee Rate"
              value={
                feeRate !== undefined
                  ? `${(Number(feeRate) / 100).toFixed(2)}% (${feeRate} bps)`
                  : '…'
              }
            />
            <InfoRow
              label="Owner"
              value={owner ? shorten(owner) : '…'}
              mono
            />
            <InfoRow
              label="Withdrawer"
              value={withdrawer ? shorten(withdrawer) : '…'}
              mono
            />
            <InfoRow
              label="Pending Owner"
              value={
                pendingOwner && pendingOwner !== ZERO
                  ? shorten(pendingOwner)
                  : 'None'
              }
              mono
            />
          </div>

          {/* ── Native Balance ── */}
          <div className="px-5 py-4">
            <div className="flex items-center justify-between gap-3 flex-wrap">
              <div>
                <p className="text-xs text-gray-500 mb-0.5">Native Balance</p>
                <p className="text-white font-medium">{nativeFmt}</p>
              </div>
              <div className="flex gap-2">
                {isWrongChain ? (
                  <button
                    onClick={() => switchChain({ chainId: contract.chainId })}
                    className="px-3 py-1.5 text-xs rounded bg-orange-800 hover:bg-orange-700 transition-colors"
                  >
                    Switch to {chainName}
                  </button>
                ) : canWithdraw ? (
                  <button
                    onClick={() =>
                      execute('Withdraw All Native', () =>
                        writeContractAsync({
                          address: contract.address,
                          abi: feeCollectorAbi,
                          functionName: 'withdrawAllNative',
                          args: [userAddr!],
                          chainId: contract.chainId,
                        }),
                      )
                    }
                    disabled={!nativeBal || nativeBal.value === 0n || isBusy}
                    className="px-3 py-1.5 text-xs rounded bg-emerald-800 hover:bg-emerald-700 disabled:opacity-40 transition-colors"
                  >
                    {pendingLabel === 'Withdraw All Native' && isBusy
                      ? 'Confirming…'
                      : 'Withdraw All → me'}
                  </button>
                ) : null}
              </div>
            </div>
          </div>

          {/* ── Token Balances (swap only) ── */}
          {contract.type === 'swap' && (
            <div className="px-5 py-4">
              <div className="flex items-center justify-between gap-3 mb-3">
                <p className="text-xs font-medium text-gray-400 uppercase tracking-wide">
                  Token Balances
                </p>
                <div className="flex gap-1.5">
                  <input
                    type="text"
                    placeholder="0x… token address"
                    value={tokenInput}
                    onChange={(e) => setTokenInput(e.target.value)}
                    onKeyDown={(e) => e.key === 'Enter' && addToken()}
                    className="px-2 py-1 text-xs rounded bg-gray-800 border border-gray-700 text-white placeholder-gray-600 w-40 focus:outline-none focus:border-gray-500"
                  />
                  <button
                    onClick={addToken}
                    disabled={!isAddress(tokenInput)}
                    className="px-2 py-1 text-xs rounded bg-blue-900 hover:bg-blue-800 disabled:opacity-40 transition-colors"
                  >
                    + Add
                  </button>
                </div>
              </div>

              {watchedTokens.length === 0 ? (
                <p className="text-xs text-gray-600 italic">
                  No tokens tracked. Paste a token contract address above.
                </p>
              ) : (
                <div>
                  {watchedTokens.map((t) => (
                    <div key={t} className="flex items-center gap-1">
                      <div className="flex-1 min-w-0">
                        <TokenRow
                          tokenAddr={t}
                          contractAddr={contract.address}
                          chainId={contract.chainId}
                          canWithdraw={canWithdraw && !isWrongChain}
                          onWithdrawAll={(addr) =>
                            execute('Withdraw Token', () =>
                              writeContractAsync({
                                address: contract.address,
                                abi: feeCollectorAbi,
                                functionName: 'withdrawAll',
                                args: [addr, userAddr!],
                                chainId: contract.chainId,
                              }),
                            )
                          }
                          disabled={isBusy}
                        />
                      </div>
                      <button
                        onClick={() => removeToken(t)}
                        className="text-gray-700 hover:text-red-500 text-xs px-1 transition-colors"
                        title="Remove token"
                      >
                        ✕
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* ── Accept Ownership (pending owner only) ── */}
          {isPendingOwner && !isWrongChain && (
            <div className="px-5 py-4 bg-orange-950/20 border-l-4 border-orange-700">
              <p className="text-sm text-orange-300 mb-3">
                🔔 You are the pending owner of this contract.
              </p>
              <button
                onClick={() =>
                  execute('Accept Ownership', () =>
                    writeContractAsync({
                      address: contract.address,
                      abi: feeCollectorAbi,
                      functionName: 'acceptOwnership',
                      chainId: contract.chainId,
                    }),
                  )
                }
                disabled={isBusy}
                className="px-4 py-2 text-sm rounded bg-orange-800 hover:bg-orange-700 disabled:opacity-40 transition-colors"
              >
                {pendingLabel === 'Accept Ownership' && isBusy
                  ? 'Confirming…'
                  : 'Accept Ownership'}
              </button>
            </div>
          )}

          {/* ── Admin Panel (owner only) ── */}
          {isOwner && !isWrongChain && (
            <div className="px-5 py-4 space-y-4">
              <p className="text-xs font-medium text-yellow-500 uppercase tracking-wide">
                Admin Actions
              </p>

              <ActionRow
                label="Fee Rate (basis points)"
                placeholder={feeRate !== undefined ? String(feeRate) : '75'}
                hint="75 = 0.75% · max 1000 = 10%"
                value={feeRateInput}
                onChange={setFeeRateInput}
                btnLabel="Set"
                loading={pendingLabel === 'Set Fee Rate' && isBusy}
                onSubmit={() =>
                  execute('Set Fee Rate', () =>
                    writeContractAsync({
                      address: contract.address,
                      abi: feeCollectorAbi,
                      functionName: 'setFeeRate',
                      args: [BigInt(feeRateInput)],
                      chainId: contract.chainId,
                    }),
                  )
                }
                disabled={
                  !feeRateInput ||
                  isNaN(Number(feeRateInput)) ||
                  Number(feeRateInput) > 1000 ||
                  isBusy
                }
              />

              <ActionRow
                label="New Withdrawer"
                placeholder="0x…"
                value={withdrawerInput}
                onChange={setWithdrawerInput}
                btnLabel="Set"
                loading={pendingLabel === 'Set Withdrawer' && isBusy}
                onSubmit={() =>
                  execute('Set Withdrawer', () =>
                    writeContractAsync({
                      address: contract.address,
                      abi: feeCollectorAbi,
                      functionName: 'setWithdrawer',
                      args: [withdrawerInput as `0x${string}`],
                      chainId: contract.chainId,
                    }),
                  )
                }
                disabled={!isAddress(withdrawerInput) || isBusy}
              />

              <ActionRow
                label="Transfer Ownership (two-step)"
                placeholder="0x… new owner"
                hint="New owner must call acceptOwnership() to confirm"
                value={ownerInput}
                onChange={setOwnerInput}
                btnLabel="Propose"
                loading={pendingLabel === 'Transfer Ownership' && isBusy}
                onSubmit={() =>
                  execute('Transfer Ownership', () =>
                    writeContractAsync({
                      address: contract.address,
                      abi: feeCollectorAbi,
                      functionName: 'transferOwnership',
                      args: [ownerInput as `0x${string}`],
                      chainId: contract.chainId,
                    }),
                  )
                }
                disabled={!isAddress(ownerInput) || isBusy}
                danger
              />
            </div>
          )}

          {/* ── Tx Status Bar ── */}
          {(isBusy || isConfirmed || txError) && (
            <div
              className={`px-5 py-3 text-sm flex items-center gap-3 ${
                txError
                  ? 'bg-red-950/40 text-red-400'
                  : isConfirmed
                  ? 'bg-green-950/40 text-green-400'
                  : 'bg-gray-800 text-gray-400'
              }`}
            >
              <span>
                {txError
                  ? `❌ ${txError}`
                  : isBusy
                  ? `⏳ ${pendingLabel} — waiting for confirmation…`
                  : isConfirmed
                  ? `✅ ${pendingLabel} confirmed`
                  : null}
              </span>
              {txHash && (
                <a
                  href={`${contract.explorerUrl}/tx/${txHash}`}
                  target="_blank"
                  rel="noreferrer"
                  className="font-mono text-xs underline opacity-60 hover:opacity-100 ml-auto"
                >
                  {shorten(txHash)}
                </a>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
