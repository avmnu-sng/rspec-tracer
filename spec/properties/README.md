# Property-based tests

Properties are invariants that must hold for *any* valid input. Each
property runs against 100 generated inputs (by default); a failure
prints the counter-example so you can reproduce it.

## Framework

[rantly](https://github.com/rantly-rb/rantly) via
`rantly/rspec_extensions`. Pure-Ruby, works on MRI 3.1+ and JRuby 9.4.

## Running

    task test:property
    bundle exec rspec spec/properties/time_formatter_spec.rb   # one file

## Writing a property

```ruby
require 'rantly/rspec_extensions'

RSpec.describe Foo do
  it 'never returns nil for a non-empty alpha string' do
    property_of { string(:alpha).reject(&:empty?) }.check(100) do |s|
      expect(Foo.bar(s)).not_to be_nil
    end
  end
end
```

Common generators: `integer`, `range(lo, hi)`, `float`, `string(:alpha)`,
`array(n) { <gen> }`, `boolean`, `choose(a, b, c)`. Build composites
inside the block using plain Ruby.

## Reproducing a failure

rantly prints the failing value to stdout, e.g.:

    FAILURE - 42 successful tests, failed on:
    [17, -3, 9001]

Copy that value into a regular spec to debug it as a fixed case:

```ruby
it 'repro of property failure' do
  expect(Foo.bar([17, -3, 9001])).not_to be_nil
end
```

## Scope of this directory

First-order invariants on leaf modules — things like formatter output
shape, identity-hash determinism, filter monotonicity. Cross-cutting
scenarios live in `spec/integration/`.
