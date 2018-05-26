defmodule Tortoise.Transport do
  @moduledoc """
  Abstraction for working with network connections; this is done to
  normalize the `:ssl` and `:gen_tcp` modules, so they get a similar
  interface.

  This work has been heavily inspired by the Ranch project by
  NineNines.
  """

  @enforce_keys [:type, :host, :port]
  defstruct type: nil, host: nil, port: nil, opts: []

  @type socket() :: any()
  @type opts() :: any()
  @type stats() :: any()

  @callback listen(opts()) :: {:ok, socket()} | {:error, atom()}

  @callback accept(socket(), timeout()) :: {:ok, socket()} | {:error, :closed | :timeout | atom()}

  @callback accept_ack(socket(), timeout()) :: :ok

  @callback connect(charlist(), :inet.port_number(), opts()) :: {:ok, socket()} | {:error, atom()}

  @callback connect(charlist(), :inet.port_number(), opts(), timeout()) ::
              {:ok, socket()} | {:error, atom()}

  @callback recv(socket(), non_neg_integer(), timeout()) ::
              {:ok, any()} | {:error, :closed | :timeout | atom()}

  @callback send(socket(), iodata()) :: :ok | {:error, atom()}

  @callback setopts(socket(), opts()) :: :ok | {:error, atom()}

  @callback getopts(socket(), [atom()]) :: {:ok, opts()} | {:error, atom()}

  @callback getstat(socket()) :: {:ok, stats()} | {:error, atom()}

  @callback getstat(socket(), [atom()]) :: {:ok, stats()} | {:error, atom()}

  @callback controlling_process(socket(), pid()) :: :ok | {:error, :closed | :now_owner | atom()}

  @callback peername(socket()) ::
              {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, atom()}

  @callback sockname(socket()) ::
              {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, atom()}

  @callback shutdown(socket(), :read | :write | :read_write) :: :ok | {:error, atom()}

  @callback close(socket()) :: :ok
end
