defmodule Tortoise.Registry do
  @moduledoc false

  @type client_id :: term()
  @type via :: {:via, Registry, {__MODULE__, {module(), client_id()}}}

  @spec via_name(module(), client_id()) :: via() | pid()
  def via_name(_module, pid) when is_pid(pid), do: pid

  def via_name(module, client_id) do
    {:via, Registry, reg_name(module, client_id)}
  end

  @spec reg_name(module(), client_id()) :: {__MODULE__, {module(), client_id()}}
  def reg_name(module, client_id) do
    {__MODULE__, {module, client_id}}
  end

  @spec meta(key :: term()) :: :ok
  def meta(key) do
    Registry.meta(__MODULE__, key)
  end

  @spec put_meta(key :: term(), value :: term()) :: :ok
  def put_meta(key, value) do
    :ok = Registry.put_meta(__MODULE__, key, value)
  end

  @spec delete_meta(key :: term()) :: :ok | no_return
  def delete_meta(key) do
    try do
      :ets.delete(__MODULE__, key)
      :ok
    catch
      :error, :badarg ->
        raise ArgumentError, "unknown registry: #{inspect(__MODULE__)}"
    end
  end
end
