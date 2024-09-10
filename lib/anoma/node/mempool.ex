defmodule Anoma.Node.Mempool do
  @moduledoc """

  """

  alias Anoma.{Block, Transaction, Serializer}
  alias Anoma.Block.Base
  alias __MODULE__
  alias Anoma.Node.Mempool.Ordering
  alias Anoma.Node.Router

  use TypedStruct

  @typedoc """
  I am a list of transaction candidates.
  """
  @type transactions :: list(Transaction.t())

  @type tx_result :: pid() | {:ok, Noun.t()} | :error

  typedstruct do
    field(:transactions, %{binary() => Noun.t()})
    field(:round, non_neg_integer(), default: 0)

    field(:key, {Serializer.public_key(), Serializer.private_key()},
      default: :crypto.generate_key(:rsa, {1024, 65537})
    )

    field(:logger, Router.Addr.t(), enforce: false)
  end

  @spec init(any()) :: {:ok, Mempool.t()}
  def init(_arg) do
    :mnesia.create_table(__MODULE__.Blocks, attributes: [:round, :block])
    {:ok, %__MODULE__{}}
  end

  ############################################################
  #                      Public RPC API                      #
  ############################################################

  def tx(server, tx_w_backend, reply_to \\ nil) do
    Router.cast(server, {:tx, tx_w_backend, reply_to})
  end

  def execute(server) do
    Router.cast(server, :execute)
  end

  ############################################################
  #                    Genserver Behavior                    #
  ############################################################

  def handle_cast({:tx, tx_code, reply_to}, _from, state) do
    tx_id = :crypto.strong_rand_bytes(16)

    worker =
      Task.start(fn ->
        Anoma.Node.Mempool.Backends.execute(tx_id, tx_code, reply_to)
      end)

    nstate = %Mempool{
      state
      | transactions: Map.put(state.transactions, tx_id, {tx_code, worker})
    }

    {:noreply, nstate}
  end

  def handle_cast(:execute, _from, state) do
    # if no reply within specified time all crashes
    res_list = state.transactions |> Ordering.order()

    {writes, rem} =
      for {res, id, height} <- res_list,
          reduce: {[], state.transactions} do
        {block_writes, _remaining_txs} ->
          res =
            case res do
              :ok ->
                {height, Map.get(state.transactions, id)}

              :error ->
                {:error, Map.get(state.transactions, id)}
            end

          {[res | block_writes], Map.delete(state.transactions, id)}
      end

    tx = fn -> :mnesia.write({__MODULE__.Blocks, state.round, writes}) end
    :mnesia.transaction(tx)

    {:noreply, %__MODULE__{state | transactions: rem, round: state.round + 1}}
  end

  def handle_call(_, _, state) do
    {:reply, :ok, state}
  end

  def handle_cast(_, state) do
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end
end
