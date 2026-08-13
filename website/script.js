const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

if (!reduceMotion) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) entry.target.classList.add('is-visible');
    }
  }, { threshold: 0.18, rootMargin: '0px 0px -6% 0px' });

  document.querySelectorAll('.reveal, .demo').forEach((element) => observer.observe(element));

  const modelRows = [...document.querySelectorAll('[data-model-row]')];
  let activeModel = 0;
  if (modelRows.length) {
    modelRows[0].classList.add('active');
    window.setInterval(() => {
      modelRows[activeModel].classList.remove('active');
      activeModel = (activeModel + 1) % modelRows.length;
      modelRows[activeModel].classList.add('active');
    }, 1900);
  }
} else {
  document.querySelectorAll('.reveal, .demo').forEach((element) => element.classList.add('is-visible'));
}

document.querySelectorAll('a[href^="#"]').forEach((link) => {
  link.addEventListener('click', (event) => {
    const id = link.getAttribute('href');
    if (!id || id === '#') return;
    const target = document.querySelector(id);
    if (!target) return;
    event.preventDefault();
    target.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
  });
});
