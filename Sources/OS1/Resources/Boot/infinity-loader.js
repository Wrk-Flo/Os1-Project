// Port of OS-1's src/components/InfinityLoader.js
// (https://github.com/nickvasilescu/OS-1). Three.js import points to the
// vendored bundle; colors + easeInOutQuad are inlined to avoid extra
// fetches. Animation math is byte-for-byte the original except for
// `transitionStepRate`, which lets the boot harness compress the
// 12 s helix→ring transition into ~2 s.

import * as THREE from './three.module.min.js';

const colors = {
  coral600: 0xbc5a42,
  coral500: 0xd1684e,
  coral400: 0xd87660,
  coral300: 0xe6ad86,
  white: 0xffffff,
};

function easeInOutQuad(t, b, c, d) {
  if ((t /= d / 2) < 1) return c / 2 * t * t + b;
  return -c / 2 * ((--t) * (t - 2) - 1) + b;
}

class CustomSinCurve extends THREE.Curve {
  constructor(scale = 1) {
    super();
    this.scale = scale;
    this.length = 30;
    this.radius = 5.6;
  }

  getPoint(t, optionalTarget = new THREE.Vector3()) {
    const pi2 = Math.PI * 2;
    const x = this.length * Math.sin(pi2 * t);
    const y = this.radius * Math.cos(pi2 * 3 * t);

    let tVal = t % 0.25 / 0.25;
    tVal = t % 0.25 - (2 * (1 - tVal) * tVal * -0.0185 + tVal * tVal * 0.25);

    if (Math.floor(t / 0.25) === 0 || Math.floor(t / 0.25) === 2) {
      tVal *= -1;
    }

    const z = this.radius * Math.sin(pi2 * 2 * (t - tVal));

    return optionalTarget.set(x, y, z).multiplyScalar(this.scale);
  }
}

export class InfinityLoader {
  constructor(canvas, options = {}) {
    this.canvas = canvas;
    this.canvasSize = 500;
    this.rotateValue = 0.035;
    this.acceleration = 0;
    this.animateStep = 0;
    this.toEnd = false;
    this.isComplete = false;
    this.morphProgress = 0;
    this.onComplete = null;
    this.wobbleTime = 0;
    // OS-1 default: +1 per frame → 720 frames → ~12 s. The boot
    // harness passes 6 to compress the transition into ~2 s.
    this.transitionStepRate = options.transitionStepRate ?? 1;

    this.init();
  }

  init() {
    this.scene = new THREE.Scene();
    this.group = new THREE.Group();
    this.scene.add(this.group);

    this.camera = new THREE.PerspectiveCamera(65, 1, 1, 10000);
    this.camera.position.z = 150;

    this.createMesh();
    this.createRing();

    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      antialias: true,
      alpha: true,
    });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setClearColor(0x000000, 0);

    this.canvas.style.opacity = '0';
    this.isAnimating = false;

    this.resize();
    this.bindEvents();
  }

  start() {
    if (this.isAnimating) return;
    this.isAnimating = true;
    this.canvas.style.opacity = '1';
    this.canvas.style.transition = 'opacity 0.5s ease';
    this.animate();
  }

  createMesh() {
    const path = new CustomSinCurve(1);
    const geometry = new THREE.TubeGeometry(path, 200, 1.1, 2, true);
    const material = new THREE.MeshBasicMaterial({
      color: colors.white,
      transparent: true,
      opacity: 1,
    });
    this.mesh = new THREE.Mesh(geometry, material);
    this.group.add(this.mesh);
  }

  createRing() {
    const radius = 6.5;
    const tubeRadius = 0.4;
    const geometry = new THREE.TorusGeometry(radius, tubeRadius, 16, 32);
    const material = new THREE.MeshBasicMaterial({
      color: colors.white,
      opacity: 0,
      transparent: true,
    });
    this.ring = new THREE.Mesh(geometry, material);
    this.ring.position.x = 31.1;
    this.ring.rotation.y = Math.PI / 2;
    this.group.add(this.ring);
  }

  resize() {
    const minSide = Math.min(window.innerWidth, window.innerHeight);
    this.canvasSize = Math.max(300, Math.min(500, minSide * 0.8));

    this.canvas.style.width = `${this.canvasSize}px`;
    this.canvas.style.height = `${this.canvasSize}px`;
    this.renderer.setSize(this.canvasSize, this.canvasSize);
  }

  bindEvents() {
    this.handleResize = this.resize.bind(this);
    window.addEventListener('resize', this.handleResize);
  }

  unbindEvents() {
    window.removeEventListener('resize', this.handleResize);
  }

  triggerTransition() {
    this.toEnd = true;
  }

  animate = () => {
    if (this.isComplete || !this.isAnimating) return;

    this.animateStep = Math.max(
      0,
      Math.min(720, this.toEnd ? this.animateStep + this.transitionStepRate : this.animateStep - 4)
    );
    this.acceleration = easeInOutQuad(this.animateStep, 0, 1, 720);

    this.mesh.rotation.x += this.rotateValue + this.acceleration;

    if (this.acceleration > 0.35) {
      let progress = (this.acceleration - 0.35) / 0.65;
      this.group.rotation.y = -Math.PI / 2 * progress;
      this.group.position.z = 50 * progress;

      const morphProgress = Math.max(0, (this.acceleration - 0.45) / 0.54);

      if (morphProgress > 0) {
        const compression = 1 - morphProgress * 0.95;
        this.mesh.scale.x = compression;
        this.mesh.scale.y = 1 - morphProgress * 0.85;
        this.mesh.scale.z = 1 - morphProgress * 0.85;
        this.mesh.position.x = morphProgress * 31.1 * 0.5;
      }

      const helixFade = Math.min(1, morphProgress / 0.4);
      this.mesh.material.opacity = 1 - helixFade;

      const ringEmergence = Math.max(0, (morphProgress - 0.35) / 0.3);
      this.ring.material.opacity = Math.min(1, ringEmergence);

      if (morphProgress > 0) {
        this.wobbleTime += 0.18;
        const chaos = Math.max(0, (1 - morphProgress) / 0.2);
        const settleEase = Math.min(1, chaos);

        const helixMomentum = this.mesh.rotation.x * 0.4 * settleEase;

        const wobbleX = Math.sin(this.wobbleTime * 1.3 + helixMomentum) * 2.5 * settleEase;
        const wobbleY = Math.PI / 2 + Math.sin(this.wobbleTime * 0.7) * 1.8 * settleEase;
        const wobbleZ = Math.cos(this.wobbleTime * 0.9 + helixMomentum * 0.5) * 2.0 * settleEase;
        this.ring.rotation.x = wobbleX;
        this.ring.rotation.y = wobbleY;
        this.ring.rotation.z = wobbleZ;

        const baseScale = 0.1 + 0.9 * morphProgress;
        const scaleWobbleX = 1 + Math.sin(this.wobbleTime * 1.7) * 0.5 * settleEase;
        const scaleWobbleY = 1 + Math.cos(this.wobbleTime * 1.1) * 0.4 * settleEase;
        const scaleWobbleZ = 1 + Math.sin(this.wobbleTime * 2.1) * 0.3 * settleEase;
        this.ring.scale.set(
          baseScale * scaleWobbleX,
          baseScale * scaleWobbleY,
          baseScale * scaleWobbleZ
        );
      } else {
        this.ring.scale.setScalar(0.1);
        this.ring.rotation.y = Math.PI / 2;
        this.mesh.scale.set(1, 1, 1);
        this.mesh.position.x = 0;
      }

      if (this.acceleration >= 0.99 && !this.isComplete) {
        this.mesh.material.opacity = 0;
        this.mesh.position.x = 0;
        this.ring.material.opacity = 1;
        this.ring.scale.setScalar(1);
        this.ring.rotation.x = 0;
        this.ring.rotation.y = Math.PI / 2;
        this.ring.rotation.z = 0;

        this.renderer.render(this.scene, this.camera);

        this.isComplete = true;
        this.unbindEvents();
        if (this.onComplete) {
          this.onComplete();
        }
        return;
      }
    } else {
      this.mesh.material.opacity = 1;
      this.ring.material.opacity = 0;
      this.group.rotation.y = 0;
      this.group.position.z = 0;
    }

    this.renderer.render(this.scene, this.camera);
    requestAnimationFrame(this.animate);
  };

  morphToDot(duration = 600) {
    return new Promise((resolve) => {
      const startTime = performance.now();
      const startScale = this.ring.scale.x;
      const targetScale = 0.15;

      const animateMorph = (currentTime) => {
        const elapsed = currentTime - startTime;
        const progress = Math.min(elapsed / duration, 1);
        const easedProgress = easeInOutQuad(progress, 0, 1, 1);

        const scale = startScale + (targetScale - startScale) * easedProgress;
        this.ring.scale.setScalar(scale);

        this.renderer.render(this.scene, this.camera);

        if (progress < 1) {
          requestAnimationFrame(animateMorph);
        } else {
          resolve();
        }
      };

      requestAnimationFrame(animateMorph);
    });
  }

  fadeOut(duration = 800) {
    return new Promise((resolve) => {
      const startTime = performance.now();

      const animateFade = (currentTime) => {
        const elapsed = currentTime - startTime;
        const progress = Math.min(elapsed / duration, 1);

        this.canvas.style.opacity = 1 - progress;

        if (progress < 1) {
          requestAnimationFrame(animateFade);
        } else {
          this.canvas.style.display = 'none';
          resolve();
        }
      };

      requestAnimationFrame(animateFade);
    });
  }

  destroy() {
    this.unbindEvents();
    this.renderer.dispose();
    this.scene.clear();
  }
}
