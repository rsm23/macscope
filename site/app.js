const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const boot = document.querySelector(".boot");
window.addEventListener("load", () => {
  window.setTimeout(() => boot?.classList.add("is-complete"), reduceMotion ? 0 : 420);
});

const header = document.querySelector("[data-header]");
const progress = document.querySelector(".page-progress span");

function updateScrollState() {
  const scrollTop = window.scrollY;
  const max = document.documentElement.scrollHeight - window.innerHeight;
  header?.classList.toggle("is-scrolled", scrollTop > 24);
  if (progress) progress.style.transform = `scaleX(${max > 0 ? scrollTop / max : 0})`;

  document.querySelectorAll("[data-parallax]").forEach((element) => {
    if (reduceMotion) return;
    const speed = Number(element.dataset.parallax || 0);
    const rect = element.getBoundingClientRect();
    const center = rect.top + rect.height / 2 - window.innerHeight / 2;
    element.style.setProperty("--scroll-shift", `${center * speed}px`);
    element.style.translate = `0 var(--scroll-shift)`;
  });
}

window.addEventListener("scroll", updateScrollState, { passive: true });
updateScrollState();

const menuToggle = document.querySelector(".menu-toggle");
const nav = document.querySelector(".site-nav");

menuToggle?.addEventListener("click", () => {
  const expanded = menuToggle.getAttribute("aria-expanded") === "true";
  menuToggle.setAttribute("aria-expanded", String(!expanded));
  nav?.classList.toggle("is-open", !expanded);
});

nav?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    menuToggle?.setAttribute("aria-expanded", "false");
    nav.classList.remove("is-open");
  });
});

const revealObserver = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      revealObserver.unobserve(entry.target);
    });
  },
  { threshold: 0.14, rootMargin: "0px 0px -7%" },
);

document
  .querySelectorAll(".reveal, .reveal-media, .draw-line, .circuit, .cta-trace")
  .forEach((element) => revealObserver.observe(element));

const capabilityCopy = {
  sound: "Independent app audio, output routing, and quick switching.",
  capture: "Screenshots, recordings, OCR, editing, and shareable local links.",
  windows: "Layouts, snapping, focus tools, and an exact-window switcher.",
  clipboard: "History, snippets, scratchpads, and a floating Finder shelf.",
  maintenance: "App removal, storage cleanup, updates, and media conversion.",
  power: "Battery insight, keep-awake control, and quiet-workflow tools.",
};

const capabilityTitle = document.querySelector("[data-capability-title]");
document.querySelectorAll("[data-capability]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll("[data-capability]").forEach((item) => {
      item.setAttribute("aria-selected", String(item === button));
    });

    if (!capabilityTitle) return;
    capabilityTitle.animate(
      [
        { opacity: 1, transform: "translateY(0)" },
        { opacity: 0, transform: "translateY(-6px)", offset: 0.48 },
        { opacity: 0, transform: "translateY(6px)", offset: 0.52 },
        { opacity: 1, transform: "translateY(0)" },
      ],
      { duration: reduceMotion ? 1 : 320, easing: "ease-out" },
    );
    capabilityTitle.textContent = capabilityCopy[button.dataset.capability];
  });
});

if (!reduceMotion && window.matchMedia("(pointer: fine)").matches) {
  document.querySelectorAll("[data-tilt]").forEach((frame) => {
    const baseTransform = getComputedStyle(frame).transform;
    frame.addEventListener("pointermove", (event) => {
      const bounds = frame.getBoundingClientRect();
      const x = (event.clientX - bounds.left) / bounds.width - 0.5;
      const y = (event.clientY - bounds.top) / bounds.height - 0.5;
      frame.style.transform = `${baseTransform === "none" ? "" : baseTransform} perspective(1500px) rotateX(${-y * 2.2}deg) rotateY(${x * 3.2}deg) translateZ(4px)`;
    });
    frame.addEventListener("pointerleave", () => {
      frame.style.transform = "";
    });
  });

  document.querySelectorAll(".magnetic").forEach((button) => {
    button.addEventListener("pointermove", (event) => {
      const bounds = button.getBoundingClientRect();
      const x = (event.clientX - bounds.left - bounds.width / 2) * 0.13;
      const y = (event.clientY - bounds.top - bounds.height / 2) * 0.13;
      button.style.setProperty("--mx", `${x}px`);
      button.style.setProperty("--my", `${y}px`);
    });
    button.addEventListener("pointerleave", () => {
      button.style.setProperty("--mx", "0px");
      button.style.setProperty("--my", "0px");
    });
  });
}

function createSignalCanvas() {
  const canvas = document.querySelector("#signal-canvas");
  if (!(canvas instanceof HTMLCanvasElement) || reduceMotion) return;

  const context = canvas.getContext("2d");
  if (!context) return;

  let width = 0;
  let height = 0;
  let dpr = 1;
  let particles = [];
  const pointer = { x: -9999, y: -9999 };

  const resize = () => {
    width = window.innerWidth;
    height = window.innerHeight;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    context.setTransform(dpr, 0, 0, dpr, 0, 0);
    const count = Math.min(58, Math.max(22, Math.floor(width / 26)));
    particles = Array.from({ length: count }, () => ({
      x: Math.random() * width,
      y: Math.random() * height,
      vx: (Math.random() - 0.5) * 0.16,
      vy: (Math.random() - 0.5) * 0.16,
      size: Math.random() * 1.1 + 0.45,
    }));
  };

  window.addEventListener("resize", resize, { passive: true });
  window.addEventListener("pointermove", (event) => {
    pointer.x = event.clientX;
    pointer.y = event.clientY;
  }, { passive: true });
  document.addEventListener("pointerleave", () => {
    pointer.x = -9999;
    pointer.y = -9999;
  });

  const render = () => {
    context.clearRect(0, 0, width, height);
    particles.forEach((particle, index) => {
      particle.x += particle.vx;
      particle.y += particle.vy;
      if (particle.x < -10) particle.x = width + 10;
      if (particle.x > width + 10) particle.x = -10;
      if (particle.y < -10) particle.y = height + 10;
      if (particle.y > height + 10) particle.y = -10;

      const pointerDistance = Math.hypot(particle.x - pointer.x, particle.y - pointer.y);
      if (pointerDistance < 130) {
        particle.x += (particle.x - pointer.x) * 0.0025;
        particle.y += (particle.y - pointer.y) * 0.0025;
      }

      context.beginPath();
      context.arc(particle.x, particle.y, particle.size, 0, Math.PI * 2);
      context.fillStyle = "rgba(80, 166, 255, 0.42)";
      context.fill();

      for (let neighborIndex = index + 1; neighborIndex < particles.length; neighborIndex += 1) {
        const neighbor = particles[neighborIndex];
        const distance = Math.hypot(particle.x - neighbor.x, particle.y - neighbor.y);
        if (distance > 112) continue;
        context.beginPath();
        context.moveTo(particle.x, particle.y);
        context.lineTo(neighbor.x, neighbor.y);
        context.strokeStyle = `rgba(41, 127, 222, ${(1 - distance / 112) * 0.12})`;
        context.lineWidth = 0.6;
        context.stroke();
      }
    });
    window.requestAnimationFrame(render);
  };

  resize();
  render();
}

createSignalCanvas();
