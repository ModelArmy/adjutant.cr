require "../spec_helper"

module Adjutant
  private def self.type_inference_test_parse(source : String) : Body
    Parser.new(source).parse
  end

  describe TypeHint do
    it "merging two KnownTypes with the same class stays that class" do
      interp, _ = make_interp
      int_cls = interp.get_global("Integer").as_rclass
      a = KnownType.new(int_cls)
      b = KnownType.new(int_cls)
      merged = TypeHint.merge(a, b).as(KnownType)
      merged.classes.should eq Set{int_cls}
    end

    it "merging a KnownType with an UnknownType yields UnknownType" do
      interp, _ = make_interp
      int_cls = interp.get_global("Integer").as_rclass
      merged = TypeHint.merge(KnownType.new(int_cls), UnknownType.new)
      merged.should be_a(UnknownType)
    end

    it "merging two different KnownTypes unions the classes" do
      interp, _ = make_interp
      int_cls = interp.get_global("Integer").as_rclass
      other_cls = RubyClass.new("Other")
      merged = TypeHint.merge(KnownType.new(int_cls), KnownType.new(other_cls)).as(KnownType)
      merged.classes.should eq Set{int_cls, other_cls}
    end
  end

  describe TypeInference do
    it "an integer literal infers as Integer" do
      interp, _ = make_interp
      inference = TypeInference.new(interp)
      body = type_inference_test_parse("5")
      type, _ = inference.infer_body(body, TypeInference::Env.new)
      type.as(KnownType).classes.should eq Set{interp.get_global("Integer").as_rclass}
    end

    it "a local var assigned an int literal is Known through later reads" do
      interp, _ = make_interp
      inference = TypeInference.new(interp)
      body = type_inference_test_parse("x = 5\nx")
      type, env = inference.infer_body(body, TypeInference::Env.new)
      type.as(KnownType).classes.should eq Set{interp.get_global("Integer").as_rclass}
      env["x"].as(KnownType).classes.should eq Set{interp.get_global("Integer").as_rclass}
    end

    it "an unassigned identifier is Unknown" do
      interp, _ = make_interp
      inference = TypeInference.new(interp)
      body = type_inference_test_parse("x")
      type, _ = inference.infer_body(body, TypeInference::Env.new)
      type.should be_a(UnknownType)
    end

    it "ClassName.new(...) infers as that class" do
      interp, _ = make_interp
      interp.eval("class Widget\nend")
      inference = TypeInference.new(interp)
      body = type_inference_test_parse("w = Widget.new")
      _, env = inference.infer_body(body, TypeInference::Env.new)
      env["w"].as(KnownType).classes.should eq Set{interp.get_global("Widget").as_rclass}
    end

    it "a var assigned the same known type in every if/else branch stays Known" do
      interp, _ = make_interp
      inference = TypeInference.new(interp)
      body = type_inference_test_parse(<<-RUBY)
        if true
          x = 5
        else
          x = 6
        end
      RUBY
      _, env = inference.infer_body(body, TypeInference::Env.new)
      env["x"].as(KnownType).classes.should eq Set{interp.get_global("Integer").as_rclass}
    end

    it "a var assigned only in the if branch (no else) degrades to Unknown after" do
      interp, _ = make_interp
      inference = TypeInference.new(interp)
      body = type_inference_test_parse(<<-RUBY)
        if true
          x = 5
        end
      RUBY
      _, env = inference.infer_body(body, TypeInference::Env.new)
      env["x"]?.should be_nil
    end

    it "a var assigned before an if, and left untouched in one branch, stays Known" do
      interp, _ = make_interp
      inference = TypeInference.new(interp)
      body = type_inference_test_parse(<<-RUBY)
        x = 5
        if true
          x = 6
        else
        end
      RUBY
      _, env = inference.infer_body(body, TypeInference::Env.new)
      env["x"].as(KnownType).classes.should eq Set{interp.get_global("Integer").as_rclass}
    end

    it "a var assigned in every case/when branch (with else) stays Known" do
      interp, _ = make_interp
      inference = TypeInference.new(interp)
      body = type_inference_test_parse(<<-RUBY)
        case 1
        when 1
          x = 5
        else
          x = 6
        end
      RUBY
      _, env = inference.infer_body(body, TypeInference::Env.new)
      env["x"].as(KnownType).classes.should eq Set{interp.get_global("Integer").as_rclass}
    end

    it "a var whose type changes inside a while loop merges to a union of both types" do
      interp, _ = make_interp
      interp.eval("class Widget\nend")
      inference = TypeInference.new(interp)
      body = type_inference_test_parse(<<-RUBY)
        x = 5
        while true
          x = Widget.new
        end
      RUBY
      _, env = inference.infer_body(body, TypeInference::Env.new)
      env["x"].as(KnownType).classes.should eq Set{interp.get_global("Integer").as_rclass, interp.get_global("Widget").as_rclass}
    end
  end
end
