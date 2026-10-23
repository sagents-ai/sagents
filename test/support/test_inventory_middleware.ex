defmodule Sagents.TestInventoryMiddleware do
  @moduledoc """
  A tool search namespace over fixed data, for live tests. Each instance takes
  a `:domain` and declares that domain as its namespace, so one module stands in
  for two domain middleware.

  ## Options

  - `:domain` - `:devices` or `:billing` (required)
  - `:test_pid` - receives `{:tool_ran, name, args}` when a tool runs

  Devices: `hq` has 17 managed devices and `warehouse` has 42. Billing: the
  current balance is 1,250 USD and the open invoice is `inv-7`.
  """

  @behaviour Sagents.Middleware

  alias LangChain.Function

  @device_counts %{"hq" => "17", "warehouse" => "42"}

  @impl true
  def init(opts) do
    config = %{domain: Keyword.fetch!(opts, :domain), test_pid: Keyword.get(opts, :test_pid)}

    case Keyword.fetch(opts, :id) do
      {:ok, id} -> {:ok, Map.put(config, :id, id)}
      :error -> {:ok, config}
    end
  end

  @impl true
  def tool_search(%{domain: :devices}),
    do: [
      namespace: "devices",
      description: "List, inspect, and restart the managed devices at a site."
    ]

  def tool_search(%{domain: :billing}),
    do: [namespace: "billing", description: "Account balance, invoices, and refunds."]

  @impl true
  def tools(%{domain: :devices} = config) do
    [
      tool(config, "devices_list", "List the managed devices at a site, with the device count.",
        site: "The site, hq or warehouse."
      ),
      tool(config, "devices_restart", "Restart a managed device by its id.", id: "The device id.")
    ]
  end

  def tools(%{domain: :billing} = config) do
    [
      tool(config, "billing_balance", "Get the account's current balance.", []),
      tool(config, "billing_invoices", "List the account's open invoices.", [])
    ]
  end

  defp tool(config, name, description, params) do
    properties =
      Map.new(params, fn {key, desc} ->
        {Atom.to_string(key), %{"type" => "string", "description" => desc}}
      end)

    Function.new!(%{
      name: name,
      description: description,
      parameters_schema: %{
        "type" => "object",
        "properties" => properties,
        "required" => Map.keys(properties)
      },
      function: fn args, _context ->
        if is_pid(config.test_pid), do: send(config.test_pid, {:tool_ran, name, args})
        {:ok, result(name, args)}
      end
    })
  end

  defp result("devices_list", %{"site" => site}) do
    count = Map.get(@device_counts, String.downcase(site), "0")
    "Site #{site} has #{count} managed devices."
  end

  defp result("devices_restart", %{"id" => id}), do: "Restart sent to #{id}."
  defp result("billing_balance", _args), do: "The current balance is 1,250 USD."
  defp result("billing_invoices", _args), do: "Open invoices: inv-7 for 300 USD, due 2026-11-01."
  defp result(_name, _args), do: "Done."
end
