defmodule Penelope.ML.Linear.ClassifierTest do
  @moduledoc """
  These tests verify the linear classifier.

  Stress tests are disabled by default, but they can be used to detect
  memory leaks in the linear NIF.
  """

  use ExUnit.Case, async: true

  import ExUnitProperties
  import Penelope.TestUtility

  alias StreamData, as: Gen
  alias Penelope.ML.Vector
  alias Penelope.ML.Linear.Classifier

  # embarrassingly separable training data
  @x_train [
    [-1,  1],
    [ 1,  1],
    [ 1, -1],
    [-1,  1],
    [ 1,  1],
    [ 1, -1]
  ] |> Enum.map(&Vector.from_list/1)

  @y_train ["c", "b", "a", "c", "b", "a"]

  @solvers [
    :l2r_lr,
    :l2r_l2loss_svc_dual,
    :l2r_l2loss_svc,
    :l2r_l1loss_svc_dual,
    :mcsvm_cs,
    :l1r_l2loss_svc,
    :l1r_lr,
    :l2r_lr_dual,
  ]

  test "fit/export/compile" do
    assert_raise fn ->
      Classifier.fit(%{}, [hd(@x_train)], @y_train)
    end
    assert_raise fn ->
      Classifier.fit(%{}, @x_train, [hd(@y_train)])
    end
    assert_raise fn ->
      Classifier.fit(%{}, @x_train, @y_train, solver: nil)
    end
    assert_raise fn ->
      Classifier.fit(%{}, @x_train, @y_train, c: 0)
    end
    assert_raise fn ->
      Classifier.fit(%{}, @x_train, @y_train, weights: %{1 => nil})
    end
    assert_raise fn ->
      Classifier.fit(%{}, @x_train, @y_train, epsilon: -1)
    end

    check all solver  <- Gen.one_of(@solvers),
              c       <- gen_pos_float(),
              weights <- Gen.list_of(gen_non_neg_float(), length: 3),
              epsilon <- Gen.uniform_float(),
              bias    <- gen_float() do
      options = [
        solver:  solver,
        c:       c,
        weights: ["a", "b", "c"]
                 |> Enum.zip(weights)
                 |> Enum.into(%{}),
        epsilon: epsilon,
        bias:    bias
      ]
      model = Classifier.fit(%{}, @x_train, @y_train, options)

      params = Classifier.export(model)
      assert params === Classifier.export(Classifier.compile(params))
    end
  end

  test "predict class" do
    model = Classifier.fit(%{}, @x_train, @y_train)
    predictions = Classifier.predict_class(model, %{}, @x_train)
    assert predictions === @y_train
  end

  test "predict probability" do
    assert_raise fn ->
      model = Classifier.fit(%{}, @x_train, @y_train)
      Classifier.predict_probability(model, %{}, @x_train)
    end

    model = Classifier.fit(%{}, @x_train, @y_train, solver: :l2r_lr)

    predictions =
      model
      |> Classifier.predict_probability(%{}, @x_train)
      |> Enum.map(&Enum.max_by(&1, fn {_, v} -> v end))
      |> Enum.map(fn {k, _} -> k end)
    assert predictions === @y_train
  end

  test "global parallelism" do
    tasks = Task.async_stream(1..1000, fn _i ->
      model = Classifier.fit(%{}, @x_train, @y_train)

      params = Classifier.export(model)
      Classifier.compile(params)

      predictions = Classifier.predict_class(model, %{}, @x_train)
      assert predictions === @y_train
    end, ordered: false)

    Stream.run(tasks)
  end

  test "shared parallelism" do
    model = Classifier.fit(%{}, @x_train, @y_train)

    tasks = Task.async_stream(1..1000, fn _i ->
      predictions = Classifier.predict_class(model, %{}, @x_train)
      assert predictions === @y_train
    end, ordered: false)

    Stream.run(tasks)
  end

  @tag :stress
  test "fit stress" do
    for _ <- 1..1_000_000 do
      Classifier.fit(%{}, @x_train, @y_train)
      :erlang.garbage_collect()
    end
  end

  @tag :stress
  test "export/compile stress" do
    model = Classifier.fit(%{}, @x_train, @y_train)

    for _ <- 1..2_500_000 do
      params = Classifier.export(model)
      Classifier.compile(params)
      :erlang.garbage_collect()
    end
  end

  @tag :stress
  test "predict stress" do
    model = Classifier.fit(%{}, @x_train, @y_train, solver: :l2r_lr)

    for _ <- 1..4_000_000 do
      Classifier.predict_class(model, %{}, @x_train)
      Classifier.predict_probability(model, %{}, @x_train)
      :erlang.garbage_collect()
    end
  end
end
