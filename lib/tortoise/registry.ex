defmodule Tortoise.Registry do
  @moduledoc false

  @type via :: {:via, Registry, {__MODULE__, {module(), Tortoise.client_id()}}}
  @type key :: atom() | tuple()

  @spec via_name(module(), Tortoise.client_id()) :: via() | pid()
  def via_name(_module, pid) when is_pid(pid), do: pid

  def via_name(module, client_id) do
    {:via, Registry, reg_name(module, client_id)}
  end

  @spec reg_name(module(), Tortoise.client_id()) :: {__MODULE__, {module(), Tortoise.client_id()}}
  def reg_name(module, client_id) do
    {__MODULE__, {module, client_id}}
  end

  @spec meta(key :: key()) :: {:ok, term()} | :error
  def meta(key) do
    Registry.meta(__MODULE__, key)
  end

  @spec put_meta(key :: key(), value :: term()) :: :ok
  def put_meta(key, value) do
    :ok = Registry.put_meta(__MODULE__, key, value)
  end
end
