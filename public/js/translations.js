var fr = {
  translation: {
    select2_placeholder: 'Sélectionner un ou plusieurs véhicules',
    unassigned: 'Non assigné',
    alert_need_file: 'Vous devez d\'abord selectionner un fichier',
    invalid_json: 'Le fichier fourni n\'est pas dans un format JSON valide :\n',
    invalid_file: 'Fichier invalide',
    enable_cluster: 'Activer les clusters',
    disable_cluster: 'Désactiver les clusters',
    optimize_loading: 'Traitement et optimisation en cours...',
    kill_optim: 'Arrêter l\'optimisation',
    error: 'Une erreure s\'est produite',
    optimize_queued: 'En attente d\'un processus disponible...',
    delete_confirm: 'Êtes vous sûr de vouloir supprimer ?',
    display_solution: 'Afficher la solution intermédiaire',
    download_csv: 'Télécharger le fichier CSV',
    download_json: 'Télécharger le fichier json',
    show_result: 'Visualiser les résultats',
    optimize_finished: 'Optimisation terminée',
    optimize_finished_error: 'Optimisation sans résultat',
    failure_call_optim: 'Erreur interne en lançant le service d\'optimisation : vérification des fichiers requise - {{error}}',
    invalid_config: 'Fichier de configuration absent',
    unauthorized_error: 'Vous n\'êtes pas autorisé',
    failure_optim: 'Impossible de maintenir la connexion avec le service d\'optimisation ({{attempts}} tentatives) : {{error}}',
    delete: 'Supprimer',
    download_optim_error: 'Télécharger le rapport d\'erreur de l\'optimisation',
    download_optim: 'Télécharger le résultat de l\'optimisation',
    current_jobs: 'Vos optimisations',
    invalid_duration: 'Durée invalide : {{duration}}',
    missing_column: 'Colonne manquante ou donnée nulle : {{columnName}}',
    same_reference: 'Référence identique détectée : {{reference}}',
    missing_file: 'Veuillez renseigner un fichier clients et un fichier véhicles.',
    error_file: 'Une erreur est survenue en lisant le fichier {{filename}} : ',
    customers: 'clients',
    vehicles: 'véhicules',
    select2_hidden_title: 'Cacher',
    select2_default_title: 'Défaut'
  }
};

var en = {
  translation: {
    select2_placeholder: 'Select one or more vehicles',
    unassigned: 'Unassigned',
    alert_need_file: 'You must first select a file',
    invalid_json: 'The file provided is not in a valid JSON format:\n',
    invalid_file: 'Invalid file',
    enable_cluster: 'Enable clusters',
    disable_cluster: 'Disable clusters',
    optimize_loading: 'Processing and optimization in progress...',
    kill_optim: 'Stop optimization',
    error: 'An error occured',
    optimize_queued: 'Waiting for an available process...',
    delete_confirm: 'Are you sure you want to delete?',
    display_solution: 'Display the intermediate solution',
    download_csv: 'Download CSV file',
    download_json: 'Download JSON file',
    show_result: 'View results',
    optimize_finished: 'Optimization completed',
    optimize_finished_error: 'optimization without result',
    failure_call_optim: 'Internal error while running the optimization service: file verification required - {{error}}\'',
    invalid_config: 'Configuration file missing',
    unauthorized_error: 'You are not authorized',
    failure_optim: 'Unable to maintain connection with optimization service ({{attempts}} attempts): {{error}}',
    delete: 'Delete',
    download_optim_error: 'Download the optimization error report',
    download_optim: 'Download the result of the optimization',
    current_jobs: 'Your optimizations',
    invalid_duration: 'Invalid duration: {{duration}}',
    missing_column: 'Missing column or null data: {{columnName}}',
    same_reference: 'Identical reference detected: {{reference}}',
    missing_file: 'Please fill in a customer file and a vehicle file.',
    error_file: 'An error occurred while reading the file {{filename}}:',
    customers: 'customers',
    vehicles: 'vehicles',
    select2_hidden_title: 'Hide',
    select2_default_title: 'Default'
  }
};

var es = {
  translation: {
    select2_placeholder: 'Seleccione uno o más vehículos',
    unassigned: 'No asignado',
    alert_need_file: 'Primero debe seleccionar un archivo',
    invalid_json: 'El archivo proporcionado no está en un formato JSON válido:\n',
    invalid_file: 'Archivo inválido',
    enable_cluster: 'Activar los clusters',
    disable_clusters: 'Desactivar los clusters',
    optimize_loading: 'Procesamiento y optimización en curso...',
    kill_optim: 'Detener la optimización',
    error: 'Se produjo un error',
    optimize_queued: 'A la espera de un proceso disponible...',
    delete_confirm: '¿Estás seguro de que quieres eliminar?',
    display_solution: 'Mostrar la solución intermedia',
    download_csv: 'Descargar archivo CSV',
    download_json: 'Descargar archivo json',
    show_result: 'Ver resultados',
    optimize_finished: 'optimización completada',
    optimize_finished_error: 'optimización sin resultado',
    failure_call_optim: 'Error interno al iniciar el servicio de optimización: se requiere verificación de archivos - {{error}}',
    invalid_config: 'Falta el archivo de configuración',
    nauthorized_error: 'No está autorizado',
    failure_optim: 'Imposible mantener la conexión con el servicio de optimización ({{attempts}} intentos): {{error}}',
    delete: 'Borrar',
    download_optim_error: 'Descargar el informe de errores de optimización',
    download_optim: 'Descargar el resultado de la optimización',
    current_jobs: 'Tus optimizaciones',
    invalid_duration: 'Duración inválida: {{duration}}',
    missing_column: 'Columna ausente o datos nulos: {{columnName}}',
    same_reference: 'Referencia idéntica detectada: {{reference}}',
    missing_file: 'Por favor, rellene una ficha de cliente y una ficha de vehículo.',
    error_file: 'Se ha producido un error al leer el archivo {{filename}}:',
    customers: 'clientes',
    vehicle: 'vehículos',
    select2_hidden_title: 'Ocultar',
    select2_default_title: 'Fallo'
  }
};


i18next.use(window.i18nextBrowserLanguageDetector).init({
  fallbackLng: 'en',
  resources: { fr: fr, en: en, es: es }
});
