defmodule BlueHeronScannerExample.Scanner do
  use GenServer

  alias BlueHeron.HCI.Command.ControllerAndBaseband.WriteLocalName
  alias BlueHeron.HCI.Command.LEController.SetScanEnable
  alias BlueHeron.HCI.Event.LEMeta.AdvertisingReport
  alias BlueHeron.HCI.Event.LEMeta.AdvertisingReport.Device

  @init_commands [%WriteLocalName{name: "BlueHeronScan"}]

  @default_uart_config %{
    device: "ttyS0",
    uart_opts: [speed: 115_200],
    init_commands: @init_commands
  }

  def start_link(config) do
    config = struct(BlueHeronTransportUART, Map.merge(@default_uart_config, config))
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Get devices.
  """
  def devices do
    GenServer.call(__MODULE__, :devices)
  end

  def clear_devices do
    GenServer.call(__MODULE__, :clear_devices)
  end

  def enable do
    GenServer.call(__MODULE__, :scan_enable, 30_000)
  end

  def disable do
    send(__MODULE__, :scan_disable)
  end

  @impl GenServer
  def init(config) do
    {:ok, ctx} = BlueHeron.transport(config)

    BlueHeron.add_event_handler(ctx)

    {:ok, %{ctx: ctx, working: false, devices: %{}, ignore_cids: []}}
  end

  @impl GenServer
  def handle_info({:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING}, state) do
    state = %{state | working: true}
    scan(state, true)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:HCI_EVENT_PACKET, %AdvertisingReport{devices: devices}}, state) do
    {:noreply, Enum.reduce(devices, state, &scan_device/2)}
  end

  @impl GenServer
  def handle_info({:HCI_EVENT_PACKET, _val}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:scan_disable, state) do
    scan(state, false)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:clear_devices, _from, state) do
    {:reply, :ok, %{state | devices: %{}}}
  end

  @impl GenServer
  def handle_call(:devices, _from, state) do
    {:reply, {:ok, state.devices}, state}
  end

  @impl GenServer
  def handle_call(:scan_enable, _from, state) do
    {:reply, scan(state, true), state}
  end

  defp scan(%{working: false}, _enable) do
    {:error, :not_working}
  end

  defp scan(%{ctx: ctx = %BlueHeron.Context{}}, enable) do
     BlueHeron.hci_command(ctx, %SetScanEnable{le_scan_enable: enable})
  end

  defp scan_device(device, state) do
    case device do
      %Device{address: addr, data: data, rss: rss} ->
        Enum.reduce(data, state, fn e, acc ->
          cond do
            is_local_name?(e) -> store_local_name(acc, addr, rss, e)
            is_mfg_data?(e) -> store_mfg_data(acc, addr, rss, e)
            true -> acc
          end
        end)

      _ ->
        state
    end
  end

  defp is_local_name?(val) do
    is_binary(val) && String.starts_with?(val, "\t") && String.valid?(val)
  end

  defp is_mfg_data?(val) do
    is_tuple(val) && elem(val, 0) == "Manufacturer Specific Data"
  end

  defp store_local_name(state, addr, rss, "\t" <> name) do
    device = Map.get(state.devices, addr, %{})
    device = Map.merge(device, %{name: name, time: DateTime.utc_now(), rss: rss, addr: addr})
    %{state | devices: Map.put(state.devices, addr, device)}
  end

  defp store_mfg_data(state, addr, rss, dt) do
    {_, mfg_data} = dt
    <<cid::little-16, sdata::binary>> = mfg_data

    unless cid in state.ignore_cids do
      device = Map.get(state.devices, addr, %{})
      sdata = Base.encode64(sdata)
      device = Map.merge(device, %{cid => sdata, time: DateTime.utc_now(), rss: rss, addr: addr})
      %{state | devices: Map.put(state.devices, addr, device)}
    else
      state
    end
  end
end
