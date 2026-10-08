import { useQuery } from '@tanstack/react-query'
import { healthRetrieveOptions } from '@/api/generated/@tanstack/react-query.gen'

function App() {
  const health = useQuery(healthRetrieveOptions())

  return (
    <main className="mx-auto flex min-h-svh max-w-md flex-col gap-4 p-4">
      <h1 className="text-2xl font-semibold">Surplus Food Marketplace</h1>
      <section className="rounded-lg border p-4 text-sm">
        <h2 className="mb-2 font-medium">API status</h2>
        {health.isPending && <p>Checking…</p>}
        {health.isError && <p className="text-red-600">API unreachable. Is Django running on :8000?</p>}
        {health.data && (
          <p className="text-green-700">
            {health.data.status}, PostGIS {health.data.postgis}
          </p>
        )}
      </section>
    </main>
  )
}

export default App
