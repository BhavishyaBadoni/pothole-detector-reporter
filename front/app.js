/**
 * Municipal Road Hazard Spatial Dashboard
 * Dehradun Municipal Corporation
 * 
 * Architecture:
 * - CONFIG: Application constants and endpoints
 * - ApiService: Pure network communication layer (fetch / patch)
 * - HazardStore: Data normalization & registry
 * - MapManager: Leaflet map canvas, marker lifecycle, and DOM updates
 * - UIManager: HUD metrics, status indicator, and toast notifications
 * - Poller: 10-second polling scheduler
 */

// =============================================================================
// 1. CONFIGURATION
// =============================================================================
const CONFIG = {
  ENDPOINTS: {
    HAZARDS: 'http://localhost:8080/api/admin/hazards',
    UPDATE: 'http://localhost:8080/api/admin/update',
    METRICS: 'http://localhost:8080/api/admin/metrics'
  },
  MAP: {
    DEFAULT_CENTER: [30.3165, 78.0322], // Dehradun, India
    DEFAULT_ZOOM: 13,
    TILE_LAYER: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
    ATTRIBUTION: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors | Dehradun Municipal GIS'
  },
  POLL_INTERVAL_MS: 10000 // 10 seconds
};

// =============================================================================
// 2. API SERVICE (Network / Data Access Layer)
// =============================================================================
class ApiService {
  /**
   * Fetches the latest hazard records from the backend
   * @returns {Promise<Array>} Array of raw hazard objects
   */
  static async getHazards() {
    const response = await fetch(CONFIG.ENDPOINTS.HAZARDS, {
      method: 'GET',
      headers: {
        'Accept': 'application/json'
      }
    });

    if (!response.ok) {
      throw new Error(`GET /hazards failed with HTTP ${response.status} (${response.statusText})`);
    }

    const data = await response.json();
    
    // Normalize data format (support both plain array or { hazards: [...] } / { data: [...] })
    if (Array.isArray(data)) {
      return data;
    } else if (Array.isArray(data.hazards)) {
      return data.hazards;
    } else if (Array.isArray(data.data)) {
      return data.data;
    } else {
      console.warn('API returned unexpected schema format:', data);
      return [];
    }
  }

  /**
   * Sends a PATCH request to update hazard lifecycle state or type
   * @param {Object} updatePayload - e.g. { id: '...', status: 'repaired' } or { id: '...', type: 'speed_breaker' }
   * @returns {Promise<Object>} API response
   */
  static async updateHazard(updatePayload) {
    const response = await fetch(CONFIG.ENDPOINTS.UPDATE, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      body: JSON.stringify(updatePayload)
    });

    if (!response.ok) {
      const errorBody = await response.text().catch(() => '');
      throw new Error(`PATCH /update failed with HTTP ${response.status}: ${errorBody || response.statusText}`);
    }

    return response.json().catch(() => ({ success: true }));
  }

  /**
   * Fetches active user metrics from the backend
   * @returns {Promise<Object>} metrics object
   */
  static async getMetrics() {
    const response = await fetch(CONFIG.ENDPOINTS.METRICS, {
      method: 'GET',
      headers: {
        'Accept': 'application/json'
      }
    });

    if (!response.ok) {
      throw new Error(`GET /metrics failed with HTTP ${response.status}`);
    }

    return await response.json();
  }
}

// =============================================================================
// 3. HAZARD STORE & DATA MODEL
// =============================================================================
class HazardStore {
  /**
   * Normalizes hazard fields from varied backend naming conventions
   * @param {Object} raw 
   * @returns {Object} normalized hazard
   */
  static normalize(raw) {
    const id = raw.id ?? raw._id ?? raw.hazard_id ?? String(Math.random());
    
    // Lat / Lng detection
    let lat = raw.lat ?? raw.latitude;
    let lng = raw.lng ?? raw.lon ?? raw.longitude;
    if (lat === undefined && Array.isArray(raw.coordinates) && raw.coordinates.length >= 2) {
      lat = raw.coordinates[0];
      lng = raw.coordinates[1];
    }

    // Type normalization
    let type = String(raw.type || 'pothole').toLowerCase().trim();
    if (type.includes('pothole')) {
      type = 'pothole';
    } else if (type.includes('speed') || type.includes('breaker')) {
      type = 'speed_breaker';
    }

    // Status normalization
    const status = String(raw.status || 'unrepaired').toLowerCase().trim();

    // AI Severity Score
    const aiSeverityScore = Number(
      raw.ai_severity_score ?? 
      raw.aiSeverityScore ?? 
      raw.severity_score ?? 
      raw.severity ?? 
      0
    );

    // Vehicle Hits count
    const vehicleHits = Number(
      raw.distinct_vehicle_hits ?? 
      raw.vehicle_hits ?? 
      raw.vehicleHits ?? 
      raw.hits ?? 
      0
    );

    return {
      id: String(id),
      lat: Number(lat),
      lng: Number(lng),
      type,
      status,
      aiSeverityScore,
      vehicleHits,
      jerks: raw.jerks || [],
      raw
    };
  }
}

// =============================================================================
// 4. MAP & DOM MANAGER
// =============================================================================
class MapManager {
  constructor() {
    this.map = null;
    // Registry of active Leaflet markers: Map<hazardId, { marker: L.Marker, data: Object }>
    this.markers = new Map();
    this.repairedCountThisSession = 0;
  }

  /**
   * Initialize Leaflet map instance centered on Dehradun
   */
  initMap() {
    this.map = L.map('map', {
      center: CONFIG.MAP.DEFAULT_CENTER,
      zoom: CONFIG.MAP.DEFAULT_ZOOM,
      zoomControl: true
    });

    // Add OpenStreetMap base tile layer
    L.tileLayer(CONFIG.MAP.TILE_LAYER, {
      maxZoom: 19,
      attribution: CONFIG.MAP.ATTRIBUTION
    }).addTo(this.map);

    // Track cursor coordinates for the HUD
    this.map.on('mousemove', (e) => {
      const coordEl = document.getElementById('cursorCoordinates');
      if (coordEl) {
        coordEl.innerHTML = `<span>Lat: ${e.latlng.lat.toFixed(4)}</span> | <span>Lng: ${e.latlng.lng.toFixed(4)}</span>`;
      }
    });
  }

  /**
   * Generates custom HTML icon for Leaflet marker based on hazard type
   * @param {string} type - 'pothole' | 'speed_breaker'
   * @returns {L.DivIcon}
   */
  createMarkerIcon(type) {
    const isPothole = type === 'pothole';
    const markerClass = isPothole ? 'hazard-marker-pothole' : 'hazard-marker-speedbreaker';
    const glyph = isPothole ? '!' : '▲';

    return L.divIcon({
      className: 'hazard-leaflet-div-icon',
      html: `
        <div class="hazard-marker-container ${markerClass}">
          <div class="marker-pulse-ring"></div>
          <div class="hazard-marker-pin">
            <span class="hazard-marker-icon-inner">${glyph}</span>
          </div>
        </div>
      `,
      iconSize: [32, 32],
      iconAnchor: [16, 28],
      popupAnchor: [0, -28]
    });
  }

  /**
   * Builds the popup HTML for a hazard
   * @param {Object} hazard 
   * @returns {string} HTML string
   */
  buildPopupHTML(hazard) {
    const isPothole = hazard.type === 'pothole';
    const typeLabel = isPothole ? 'Pothole Hazard' : 'Speed Breaker';
    const tagClass = isPothole ? 'tag-pothole' : 'tag-speedbreaker';
    
    // Severity color classification
    let severityClass = 'severity-low';
    if (hazard.aiSeverityScore >= 0.7 || hazard.aiSeverityScore >= 7) {
      severityClass = 'severity-high';
    } else if (hazard.aiSeverityScore >= 0.4 || hazard.aiSeverityScore >= 4) {
      severityClass = 'severity-med';
    }

    const formattedSeverity = typeof hazard.aiSeverityScore === 'number' 
      ? (hazard.aiSeverityScore <= 1 ? `${(hazard.aiSeverityScore * 100).toFixed(0)}%` : hazard.aiSeverityScore.toFixed(1))
      : hazard.aiSeverityScore;

    return `
      <div class="popup-card" id="popup-${hazard.id}">
        <div class="popup-header">
          <span class="popup-type-tag ${tagClass}">${typeLabel}</span>
          <span class="popup-id">ID: #${hazard.id}</span>
        </div>

        <div class="popup-body">
          <div class="popup-stats-grid">
            <div class="popup-stat-box">
              <span class="stat-label">AI Severity Score</span>
              <span class="stat-number ${severityClass}">${formattedSeverity}</span>
            </div>
            <div class="popup-stat-box">
              <span class="stat-label">Distinct Hits</span>
              <span class="stat-number">${hazard.vehicleHits} vehicles</span>
            </div>
          </div>

          <div class="popup-geo-row">
            <span>Lat: ${hazard.lat.toFixed(5)}</span>
            <span>Lng: ${hazard.lng.toFixed(5)}</span>
          </div>
          
          ${hazard.jerks && hazard.jerks.length > 0 ? `
          <div style="margin-top: 10px; border-top: 1px solid #333; padding-top: 10px;">
            <strong style="font-size: 0.85rem; color: #aaa;">Involved Vehicles:</strong>
            <ul style="margin: 5px 0 0 0; padding-left: 15px; font-size: 0.8rem; max-height: 80px; overflow-y: auto; color: #ddd;">
              ${hazard.jerks.map(j => `<li>${j.model || 'Unknown'} (${j.tyre || 'Unknown'}) - Sev: ${j.severity.toFixed(1)}</li>`).join('')}
            </ul>
          </div>
          ` : ''}
        </div>

        <div class="popup-actions">
          <button 
            type="button" 
            class="btn-action btn-repair" 
            id="btn-repair-${hazard.id}"
            onclick="window.AdminDashboard.handleMarkRepaired('${hazard.id}')"
          >
            <svg class="btn-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
              <polyline points="20 6 9 17 4 12"></polyline>
            </svg>
            <span>Mark as Repaired</span>
          </button>

          <button 
            type="button" 
            class="btn-action btn-override" 
            id="btn-override-${hazard.id}"
            onclick="window.AdminDashboard.handleOverrideSpeedBreaker('${hazard.id}')"
            ${!isPothole ? 'disabled title="Already a speed breaker"' : ''}
          >
            <svg class="btn-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M16 3h5v5M4 20L21 3M21 16v5h-5M15 15l6 6M4 4l5 5"/>
            </svg>
            <span>${isPothole ? 'Override to Speed Breaker' : 'Configured as Speed Breaker'}</span>
          </button>
        </div>
      </div>
    `;
  }

  /**
   * Syncs the map with fresh hazard data from API poll
   * Filters for status === 'unrepaired'
   * @param {Array<Object>} rawHazardsList 
   */
  syncHazards(rawHazardsList) {
    const unrepairedHazards = rawHazardsList
      .map(raw => HazardStore.normalize(raw))
      .filter(h => h.status === 'unrepaired' && !isNaN(h.lat) && !isNaN(h.lng));

    const currentIds = new Set(unrepairedHazards.map(h => h.id));

    // 1. Remove markers that are no longer unrepaired in the backend
    for (const [id, entry] of this.markers.entries()) {
      if (!currentIds.has(id)) {
        this.map.removeLayer(entry.marker);
        this.markers.delete(id);
      }
    }

    // 2. Add or update active markers
    unrepairedHazards.forEach(hazard => {
      if (this.markers.has(hazard.id)) {
        const entry = this.markers.get(hazard.id);
        const oldData = entry.data;

        // If type or severity changed, update marker icon and popup
        if (oldData.type !== hazard.type) {
          entry.marker.setIcon(this.createMarkerIcon(hazard.type));
        }

        // Update popup content and stored data
        entry.data = hazard;
        entry.marker.setPopupContent(this.buildPopupHTML(hazard));
      } else {
        // Create new Leaflet Marker
        const marker = L.marker([hazard.lat, hazard.lng], {
          icon: this.createMarkerIcon(hazard.type),
          title: `Hazard #${hazard.id} (${hazard.type})`
        });

        marker.bindPopup(this.buildPopupHTML(hazard), {
          maxWidth: 320,
          minWidth: 300,
          className: 'hazard-leaflet-popup'
        });

        marker.addTo(this.map);
        this.markers.set(hazard.id, { marker, data: hazard });
      }
    });

    // 3. Update HUD metrics
    this.updateMetrics();
  }

  /**
   * Lifecycle Handler: Mark Hazard as Repaired
   * Sends PATCH request, removes marker from DOM on success
   * @param {string} hazardId 
   */
  async markAsRepaired(hazardId) {
    const entry = this.markers.get(hazardId);
    if (!entry) return;

    const repairBtn = document.getElementById(`btn-repair-${hazardId}`);
    if (repairBtn) {
      repairBtn.disabled = true;
      repairBtn.innerHTML = `<span>Updating...</span>`;
    }

    try {
      // Send PATCH to update status
      await ApiService.updateHazard({
        id: hazardId,
        status: 'repaired'
      });

      // Instantly remove marker from map DOM without page refresh
      this.map.closePopup();
      this.map.removeLayer(entry.marker);
      this.markers.delete(hazardId);
      this.repairedCountThisSession++;

      // Update HUD metrics
      this.updateMetrics();

      UIManager.showToast(`Hazard #${hazardId} marked as Repaired`, 'success');
    } catch (error) {
      console.error(`Failed to repair hazard #${hazardId}:`, error);
      if (repairBtn) {
        repairBtn.disabled = false;
        repairBtn.innerHTML = `<span>Retry Repair</span>`;
      }
      UIManager.showToast(`Error: ${error.message}`, 'error');
    }
  }

  /**
   * Lifecycle Handler: Override Hazard to Speed Breaker
   * Sends PATCH request, instantly updates marker color to Orange
   * @param {string} hazardId 
   */
  async overrideToSpeedBreaker(hazardId) {
    const entry = this.markers.get(hazardId);
    if (!entry) return;

    const overrideBtn = document.getElementById(`btn-override-${hazardId}`);
    if (overrideBtn) {
      overrideBtn.disabled = true;
      overrideBtn.innerHTML = `<span>Overriding...</span>`;
    }

    try {
      // Send PATCH to update type
      await ApiService.updateHazard({
        id: hazardId,
        type: 'speed_breaker'
      });

      // Update data model
      entry.data.type = 'speed_breaker';

      // Instantly change marker icon & color to Orange on the map DOM
      entry.marker.setIcon(this.createMarkerIcon('speed_breaker'));

      // Update popup content with new state
      entry.marker.setPopupContent(this.buildPopupHTML(entry.data));

      // Update HUD metrics
      this.updateMetrics();

      UIManager.showToast(`Hazard #${hazardId} overridden to Speed Breaker`, 'info');
    } catch (error) {
      console.error(`Failed to override hazard #${hazardId}:`, error);
      if (overrideBtn) {
        overrideBtn.disabled = false;
        overrideBtn.innerHTML = `<span>Retry Override</span>`;
      }
      UIManager.showToast(`Error: ${error.message}`, 'error');
    }
  }

  /**
   * Re-computes and updates HUD metric counts
   */
  updateMetrics() {
    let potholeCount = 0;
    let speedBreakerCount = 0;

    for (const [, entry] of this.markers.entries()) {
      if (entry.data.type === 'pothole') {
        potholeCount++;
      } else if (entry.data.type === 'speed_breaker') {
        speedBreakerCount++;
      }
    }

    const totalUnrepaired = potholeCount + speedBreakerCount;

    UIManager.updateCount('countPotholes', potholeCount);
    UIManager.updateCount('countSpeedBreakers', speedBreakerCount);
    UIManager.updateCount('countTotal', totalUnrepaired);
    UIManager.updateCount('countRepaired', this.repairedCountThisSession);
  }

  /**
   * Reset view to Dehradun center
   */
  recenter() {
    if (this.map) {
      this.map.flyTo(CONFIG.MAP.DEFAULT_CENTER, CONFIG.MAP.DEFAULT_ZOOM, {
        duration: 1.2
      });
    }
  }
}

// =============================================================================
// 5. UI MANAGER & TOAST SYSTEM
// =============================================================================
class UIManager {
  static updateCount(elementId, value) {
    const el = document.getElementById(elementId);
    if (el) {
      el.textContent = value;
    }
  }

  static setPollingState(state, message) {
    const pill = document.getElementById('pollingStatusPill');
    const text = document.getElementById('pollingStatusText');
    if (!pill || !text) return;

    pill.className = `live-pill ${state}`;
    text.textContent = message;
  }

  static showToast(message, type = 'info') {
    const container = document.getElementById('toastContainer');
    if (!container) return;

    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;

    container.appendChild(toast);

    setTimeout(() => {
      toast.classList.add('fade-out');
      setTimeout(() => {
        if (toast.parentNode) toast.parentNode.removeChild(toast);
      }, 300);
    }, 4000);
  }
}

// =============================================================================
// 6. APPLICATION CONTROLLER & POLLING ENGINE
// =============================================================================
class AppController {
  constructor() {
    this.mapManager = new MapManager();
    this.pollTimer = null;
    this.isPolling = false;
  }

  async init() {
    // 1. Initialize Map
    this.mapManager.initMap();

    // 2. Bind DOM controls
    this.bindEvents();

    // 3. Perform initial fetch
    await this.fetchAndSync();

    // 4. Start 10-second polling loop
    this.startPolling();
  }

  bindEvents() {
    // Recenter map button
    const btnRecenter = document.getElementById('btnRecenterMap');
    if (btnRecenter) {
      btnRecenter.addEventListener('click', () => this.mapManager.recenter());
    }

    // Refresh now button
    const btnRefresh = document.getElementById('btnRefreshNow');
    if (btnRefresh) {
      btnRefresh.addEventListener('click', async () => {
        btnRefresh.classList.add('is-spinning');
        await this.fetchAndSync();
        setTimeout(() => btnRefresh.classList.remove('is-spinning'), 600);
      });
    }
  }

  async fetchAndSync() {
    if (this.isPolling) return;
    this.isPolling = true;

    UIManager.setPollingState('syncing', 'Syncing...');

    try {
      const hazards = await ApiService.getHazards();
      this.mapManager.syncHazards(hazards);

      try {
        const metrics = await ApiService.getMetrics();
        UIManager.updateCount('countActiveUsers', metrics.active_users || 0);
      } catch (metricsErr) {
        console.warn('Failed to fetch metrics:', metricsErr.message);
      }

      UIManager.setPollingState('live', `Live (10s Polling)`);
    } catch (err) {
      console.warn('Polling error (Make sure backend is running at http://localhost:8001):', err.message);
      UIManager.setPollingState('error', 'Sync Failed (Retrying in 10s)');
    } finally {
      this.isPolling = false;
    }
  }

  startPolling() {
    if (this.pollTimer) clearInterval(this.pollTimer);
    this.pollTimer = setInterval(() => {
      this.fetchAndSync();
    }, CONFIG.POLL_INTERVAL_MS);
  }
}

// =============================================================================
// 7. GLOBAL BOOTSTRAP
// =============================================================================
document.addEventListener('DOMContentLoaded', () => {
  const app = new AppController();
  app.init();

  // Expose global handles for popup inline event handlers
  window.AdminDashboard = {
    handleMarkRepaired: (id) => app.mapManager.markAsRepaired(id),
    handleOverrideSpeedBreaker: (id) => app.mapManager.overrideToSpeedBreaker(id),
    app
  };
});
