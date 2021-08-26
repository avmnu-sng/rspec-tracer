# Contributing

If you discover issues, have ideas for improvements or new features,
please report them to the [issue tracker][1] of the repository or
submit a pull request. Please, try to follow these guidelines when you
do so.

## Issue reporting

- Check that the issue has not already been reported.
- Check that the issue has not already been fixed.
- Be clear, concise and precise in your description of the problem.
- Include Ruby, RSpecTracer, and RSpec version. Also include Simplecov version if applicable.

## Pull requests

- Read [how to properly contribute to open source projects on GitHub][2].
- Fork the project.
- Write [good commit messages][3].
- Use the same coding conventions as the rest of the project.
- If your change has a corresponding open GitHub issue, 
prefix the commit message with `[Fix #github-issue-number]`.
- Make sure to add tests for it.
- Make sure to run `bundle exec rake assets:precompile` in
`lib/rspec_tracer/html_reporter` if changing `JavaScript` and `CSS` files.
- Make sure to run `bundle exec rake`.
- [Squash related commits together][4].
- Open a [pull request][5] that relates to *only* one subject with a 
clear title and description in grammatically correct, complete sentences.

[1]: https://github.com/avmnu-sng/rspec-tracer/issues
[2]: https://www.gun.io/blog/how-to-github-fork-branch-and-pull-request
[3]: https://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html
[4]: http://gitready.com/advanced/2009/02/10/squashing-commits-with-rebase.html
[5]: https://help.github.com/articles/about-pull-requests
