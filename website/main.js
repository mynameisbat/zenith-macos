// The only script on the page: the "Copy" button of the build commands.
(function () {
  var toast = document.getElementById('toast');
  var timer;

  function say(message) {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(timer);
    timer = setTimeout(function () { toast.classList.remove('show'); }, 1800);
  }

  document.querySelectorAll('[data-copy]').forEach(function (button) {
    button.addEventListener('click', function () {
      var source = document.querySelector(button.getAttribute('data-copy'));
      if (!source) return;
      var text = source.textContent;
      var done = function () { say('Copied'); };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { say('Select the text and copy it'); });
      } else {
        say('Select the text and copy it');
      }
    });
  });
})();
