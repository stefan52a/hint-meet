package nl.zoofit.hintmeet

import androidx.lifecycle.ViewModel
import nl.zoofit.hintmeet.pairing.Pairing
import nl.zoofit.hintmeet.session.Session

/** Dun laagje voor de schermen: alles staat in de Session (die ook de opnameservice gebruikt). */
class AppViewModel : ViewModel() {
    val pairing = Session.pairing
    val connected = Session.connected
    val gateway = Session.gateway
    val projects = Session.projects
    val meeting = Session.meeting
    val pendingPairing = Session.pendingPairing
    val error = Session.error
    val alarms = Session.alarmsNow
    val liveness = Session.liveness
    val sayState = Session.sayState
    val find = Session.find
    val folders = Session.folders
    val kbTask = Session.kbTask
    val doc = Session.doc
    val removing = Session.removing

    fun pair(uri: String?): String? = Session.pair(uri)
    fun offerPairing(uri: String?) = Session.offerPairing(uri)
    fun confirmPairing(shown: Pairing, accept: Boolean) = Session.confirmPairing(shown, accept)
    fun unpair() = Session.unpair()
    fun start(projects: List<String>, language: String, info: String) = Session.start(projects, language, info)
    fun stop() = Session.stop()
    fun feedback(id: Int, rating: Int) = Session.feedback(id, rating)
    fun say(text: String): String? = Session.say(text)
    fun clearSayError() = Session.clearSayError()
    fun search(query: String, projects: List<String> = emptyList()) = Session.search(query, projects)
    fun openFind(projects: List<String>) = Session.openFind(projects)
    fun dismissMeeting() = Session.dismissMeeting()
    fun listDirs(path: String?) = Session.listDirs(path)
    fun addFolder(path: String) = Session.addFolder(path)
    fun closeFolders() = Session.closeFolders()
    fun openDoc(ref: String, path: String?) = Session.openDoc(ref, path)
    fun closeDoc() = Session.closeDoc()
    fun removeProject(project: String) = Session.removeProject(project)
}
