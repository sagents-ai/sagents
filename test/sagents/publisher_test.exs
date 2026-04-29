defmodule Sagents.PublisherTest do
  use ExUnit.Case, async: true

  alias Sagents.Publisher
  alias Sagents.Publisher.State, as: PubState

  defmodule TestProducer do
    use GenServer
    use Sagents.Publisher, state_field: :publisher

    defstruct publisher: nil

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, opts)
    end

    @impl true
    def init(_opts) do
      Process.flag(:trap_exit, true)
      {:ok, %__MODULE__{publisher: PubState.new([:main, :debug])}}
    end

    def emit(server, channel, event) do
      GenServer.cast(server, {:emit, channel, event})
    end

    def get_publisher(server), do: GenServer.call(server, :get_publisher)

    @impl true
    def handle_cast({:emit, channel, event}, state) do
      Publisher.broadcast(state.publisher, channel, event)
      {:noreply, state}
    end

    @impl true
    def handle_call(:get_publisher, _from, state) do
      {:reply, state.publisher, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, pid, _reason} = msg, state) do
      case Publisher.handle_down(state.publisher, ref, pid) do
        {:matched, new_pub} ->
          {:noreply, %{state | publisher: new_pub}}

        :no_match ->
          {:stop, {:unexpected_down, msg}, state}
      end
    end
  end

  describe "subscribe/3 and broadcast/3" do
    test "delivers events to a single subscriber on the main channel" do
      {:ok, pid} = TestProducer.start_link()

      {:ok, ^pid, _ref} = Publisher.subscribe(pid)
      TestProducer.emit(pid, :main, {:hello, 1})

      assert_receive {:hello, 1}, 100
    end

    test "fans out to multiple subscribers" do
      {:ok, server} = TestProducer.start_link()

      parent = self()

      sub_a =
        spawn_link(fn ->
          Publisher.subscribe(server)
          send(parent, :sub_a_ready)

          receive do
            msg -> send(parent, {:a, msg})
          end
        end)

      sub_b =
        spawn_link(fn ->
          Publisher.subscribe(server)
          send(parent, :sub_b_ready)

          receive do
            msg -> send(parent, {:b, msg})
          end
        end)

      assert_receive :sub_a_ready
      assert_receive :sub_b_ready

      TestProducer.emit(server, :main, :ping)

      assert_receive {:a, :ping}, 100
      assert_receive {:b, :ping}, 100

      Process.exit(sub_a, :kill)
      Process.exit(sub_b, :kill)
    end

    test "channels are independent" do
      {:ok, server} = TestProducer.start_link()

      {:ok, ^server, _} = Publisher.subscribe(server, :main)
      TestProducer.emit(server, :debug, :debug_event)
      refute_receive :debug_event, 50

      {:ok, ^server, _} = Publisher.subscribe(server, :debug)
      TestProducer.emit(server, :debug, :debug_event_2)
      assert_receive :debug_event_2, 100
    end

    test "duplicate subscribe is idempotent" do
      {:ok, server} = TestProducer.start_link()

      {:ok, ^server, ref1} = Publisher.subscribe(server)
      {:ok, ^server, ref2} = Publisher.subscribe(server)

      assert ref1 == ref2

      pub = TestProducer.get_publisher(server)
      assert PubState.count(pub) == 1
    end

    test "unsubscribe stops delivery and demonitors" do
      {:ok, server} = TestProducer.start_link()

      {:ok, ^server, _ref} = Publisher.subscribe(server)
      :ok = Publisher.unsubscribe(server)

      pub = TestProducer.get_publisher(server)
      assert PubState.count(pub) == 0

      TestProducer.emit(server, :main, :should_not_arrive)
      refute_receive :should_not_arrive, 50
    end

    test "subscriber crash is cleaned up via :DOWN" do
      {:ok, server} = TestProducer.start_link()

      sub =
        spawn(fn ->
          Publisher.subscribe(server)

          receive do
            :stop -> :ok
          end
        end)

      # Wait for subscribe to be processed
      _ = TestProducer.get_publisher(server)
      pub = TestProducer.get_publisher(server)
      assert PubState.count(pub) == 1

      Process.exit(sub, :kill)

      # Synchronize: any subsequent call to the server is processed after the
      # :DOWN message it just sent itself, so we know cleanup has happened.
      Process.sleep(20)
      pub = TestProducer.get_publisher(server)
      assert PubState.count(pub) == 0
    end

    test "subscribe to nonexistent server returns error" do
      assert {:error, :process_not_found} =
               Publisher.subscribe({:via, Registry, {Sagents.Registry, :nonexistent}})
    end
  end

  describe "Sagents.Publisher.State.seed/2" do
    test "pre-enrolls subscribers across channels" do
      pid_a = self()

      pid_b =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      seeded =
        PubState.new([:main, :debug])
        |> PubState.seed([{:main, pid_a}, {:debug, pid_b}])

      assert PubState.subscribed?(seeded, :main, pid_a)
      assert PubState.subscribed?(seeded, :debug, pid_b)
      assert PubState.count(seeded) == 2

      Process.exit(pid_b, :kill)
    end

    test "duplicates within the seed list dedupe" do
      pid = self()

      seeded =
        PubState.new([:main])
        |> PubState.seed([{:main, pid}, {:main, pid}])

      assert PubState.count(seeded) == 1
    end
  end
end
