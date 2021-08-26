//= require_directory ./libraries/
//= require_directory ./plugins/
//= require_self

$(document).ready(function () {
  $('#examples .report-table').dataTable({
    order: [[5, 'desc']],
    paging: false
  });

  $('#examples_dependency .report-table').dataTable({
    order: [[2, 'desc']],
    paging: false
  });

  $('#files_dependency .report-table').dataTable({
    order: [[1, 'desc']],
    paging: false
  });

  $('.report_container').hide();

  $('.report_container h2').each(function () {
    var container_id = $(this).parent().attr('id');
    var group_name = $(this).find('.group_name').first().html();

    $('.group_tabs').append('<li><a href="#' + container_id + '">' + group_name + '</a></li>');
  });

  $('.group_tabs a').each(function () {
    $(this).addClass($(this).attr('href').replace('#', ''));
  });

  $('.group_tabs').on('focus', 'a', function () { $(this).blur(); });

  $('.group_tabs').on('click', 'a', function () {
    if ($(this).parent().hasClass('active')) {
      return false;
    }

    $('.group_tabs a').parent().removeClass('active');
    $(this).parent().addClass('active');
    $('.report_container').hide();
    $(".report_container" + $(this).attr('href')).show();
  });

  if (window.location.hash) {
    $('.group_tabs a.' + window.location.hash.substring(1)).click();
  } else {
    $('.group_tabs a:first').click();
  };

  $('#loading').fadeOut();
  $('#wrapper').show();
  $('.dataTables_filter input').focus();
});
