// ============================================================
//  OHIF Viewer — Application Configuration
//  MONAI Medical Imaging Platform
//  Docs: https://docs.ohif.org/configuration/configurationFiles
// ============================================================

window.config = {
  routerBasename: '/',

  // ── Extensions ─────────────────────────────────────────────
  extensions: [],
  modes: [],

  showStudyList: true,
  maxNumberOfWebWorkers: 3,

  // ── MONAI Label integration ─────────────────────────────────
  // Enables the MONAI Label panel inside OHIF (button in toolbar)
  customizationService: {
    'ohif.monaiLabel': {
      serverUrl: 'http://localhost:8000',
    },
  },

  // ── Data Sources ────────────────────────────────────────────
  dataSources: [
    {
      namespace: '@ohif/extension-default.dataSourcesModule.dicomweb',
      sourceName: 'dicomweb',
      configuration: {
        friendlyName: 'Orthanc DICOM Server',
        name: 'orthanc',
        // Requests go through the OHIF nginx proxy at /orthanc/*
        // so the browser sees same-origin URLs (no CORS issues)
        wadoUriRoot:        '/orthanc/wado',
        qidoRoot:           '/orthanc/dicom-web',
        wadoRoot:           '/orthanc/dicom-web',
        qidoSupportsIncludeField: false,
        imageRendering: 'wadors',
        thumbnailRendering: 'wadors',
        enableStudyLazyLoad: true,
        supportsFuzzyMatching: false,
        supportsWildcard: true,
        staticWado: false,
        singlepart: 'bulkdata,video,pdf',
        // No credentials here: the OHIF nginx proxy (/orthanc/*) adds them
        // server-side from docker/.env — see docker/ohif/entrypoint.sh.
      },
    },
    {
      // Local file source for development / NIfTI viewing
      namespace: '@ohif/extension-default.dataSourcesModule.dicomlocal',
      sourceName: 'dicomlocal',
      configuration: {
        friendlyName: 'Local (drag & drop)',
        name: 'dicomlocal',
      },
    },
  ],

  defaultDataSourceName: 'dicomweb',

  // ── I18n ───────────────────────────────────────────────────
  i18n: {
    providers: {
      backend: {
        loadPath: '/locales/{{lng}}/{{ns}}.json',
      },
    },
    detectionOptions: {
      order: ['localStorage', 'navigator'],
      lookupLocalStorage: 'i18nextLng',
    },
    fallbackLng: 'en',
    whitelist: ['en', 'cs'],
  },

  // ── Hotkeys ────────────────────────────────────────────────
  hotkeys: [
    { commandName: 'incrementActiveViewport',  label: 'Next Viewport',  keys: ['right'] },
    { commandName: 'decrementActiveViewport',  label: 'Prev Viewport',  keys: ['left']  },
    { commandName: 'rotateViewportCW',         label: 'Rotate CW',      keys: ['r']     },
    { commandName: 'rotateViewportCCW',        label: 'Rotate CCW',     keys: ['l']     },
    { commandName: 'invertViewport',           label: 'Invert',         keys: ['i']     },
    { commandName: 'flipViewportHorizontal',   label: 'Flip H',         keys: ['h']     },
    { commandName: 'flipViewportVertical',     label: 'Flip V',         keys: ['v']     },
    { commandName: 'scaleUpViewport',          label: 'Zoom In',        keys: ['+']     },
    { commandName: 'scaleDownViewport',        label: 'Zoom Out',       keys: ['-']     },
    { commandName: 'fitViewportToWindow',      label: 'Fit',            keys: ['=']     },
    { commandName: 'resetViewport',            label: 'Reset',          keys: ['space'] },
    { commandName: 'nextImage',                label: 'Next Slice',     keys: ['down']  },
    { commandName: 'previousImage',            label: 'Prev Slice',     keys: ['up']    },
    { commandName: 'previousViewportDisplaySet', label: 'Prev Series',  keys: ['pageup'] },
    { commandName: 'nextViewportDisplaySet',   label: 'Next Series',    keys: ['pagedown'] },
    { commandName: 'setZoomTool',              label: 'Zoom Tool',      keys: ['z']     },
    { commandName: 'setWwwcTool',              label: 'W/L Tool',       keys: ['w']     },
    { commandName: 'setPanTool',               label: 'Pan Tool',       keys: ['p']     },
    { commandName: 'setLengthTool',            label: 'Length',         keys: ['l']     },
    { commandName: 'setAngleTool',             label: 'Angle',          keys: ['a']     },
    { commandName: 'toggleOverlays',           label: 'Overlays',       keys: ['o']     },
  ],
};
